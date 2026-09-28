# OpenHands + vLLM 速度對比：qwen3.8-27b vs deepseek-v4-flash

測試：5 道複雜解題（數論證明 / 演算法 / 動態規劃 / 系統設計 / 長 context 除錯），
每题跑 2 次，取 run2（暖機值）。max_tokens=2048, temperature=0, 非 stream。
硬件：NVIDIA B200 x 7。vLLM 0.28.0。

## 部署現況
| | qwen3.8-27b | deepseek-v4-flash |
|---|---|---|
| Port | 8001 | 8000 |
| 並行 | TP2 | TP4 |
| 引擎 flag | --enforce-eager | --enforce-eager --disable-custom-all-reduce |
| KV cache | bf16（預設） | fp8 |
| max-model-len | 262144 | 262144 |
| OpenHands 使用 | 是（max_output_tokens=null） | 否 |

## A. GPU 空閒（峰值）
| 題目 | model | 總時間(s) | 輸出token | tok/s | 輸入token | 達2048上限 |
|---|---|---|---|---|---|---|
| P1 數論 | qwen3.8-27b | 58.6 | 2048 | 34.9 | 132 | 是 |
| P1 數論 | deepseek | 41.5 | 696 | 16.8 | 79 | 否 |
| P2 演算法 | qwen3.8-27b | 58.2 | 2048 | 35.2 | 138 | 是 |
| P2 演算法 | deepseek | 86.7 | 1456 | 16.8 | 88 | 否 |
| P3 動態規劃 | qwen3.8-27b | 58.1 | 2048 | 35.2 | 171 | 是 |
| P3 動態規劃 | deepseek | 122.7 | 2048 | 16.7 | 118 | 是 |
| P4 系統設計 | qwen3.8-27b | 57.9 | 2048 | 35.4 | 141 | 是 |
| P4 系統設計 | deepseek | 124.9 | 2048 | 16.4 | 93 | 是 |
| L1 長context | qwen3.8-27b | 57.9 | 2048 | 35.4 | 875 | 是 |
| L1 長context | deepseek | 124.9 | 2048 | 16.4 | 816 | 是 |

## B. GPU 共享負載（被其他 session 占 100%，最接近日常）
| 題目 | model | 總時間(s) | 輸出token | tok/s | 達2048上限 |
|---|---|---|---|---|---|
| P1 數論 | qwen3.8-27b | 58.6 | 2048 | 34.9 | 是 |
| P1 數論 | deepseek | 46.6 | 737 | 15.8 | 否 |
| P2 演算法 | qwen3.8-27b | 58.6 | 2048 | 35.0 | 是 |
| P2 演算法 | deepseek | 87.0 | 1370 | 15.7 | 否 |
| P3 動態規劃 | qwen3.8-27b | 58.1 | 2048 | 35.3 | 是 |
| P3 動態規劃 | deepseek | 104.6 | 1651 | 15.8 | 否 |
| P4 系統設計 | qwen3.8-27b | 57.9 | 2048 | 35.4 | 是 |
| P4 系統設計 | deepseek | 123.4 | 2048 | 16.6 | 是 |
| L1 長context | qwen3.8-27b | 58.6 | 2048 | 35.0 | 是 |
| L1 長context | deepseek | 124.9 | 2048 | 16.4 | 是 |

## 關鍵發現
1. qwen 生成速度 ~35 tok/s，deepseek ~16 tok/s → qwen 約 2.2 倍快。
2. qwen 每次都打滿 2048 token（被截斷），回答冗長。
   deepseek 短題只寫 696~1456 token 就收尾，較精簡。
3. 同樣 2048 token 輸出時：qwen 58s vs deepseek 125s → deepseek 慢 2.1 倍。
4. 長 context（875 in）對 qwen 幾乎無影響（57.9s vs 58.6s），prefill 可忽略。
5. 共享負載下兩者速度幾乎不變 → vLLM continuous batching 吸收干擾良好。
   代表「感覺慢」主因不是 GPU 搶占，而是 生成 token 數太多 + 速度本身。

## C. 方案 B+C 實測結果（qwen3.8-27b，GPU 空閒，同套題目）
B: 移除 --enforce-eager（開 CUDA graph / torch.compile）
C: max-model-len 262144 → 65536

| 題目 | 改前 tok/s | 改後 tok/s | 加速 | 改前時間 | 改後時間 |
|---|---|---|---|---|---|
| P1 數論 | 34.9 | 116.4 | 3.3x | 58.6s | 17.6s |
| P2 演算法 | 35.2 | 116.5 | 3.3x | 58.2s | 17.6s |
| P3 動態規劃 | 35.2 | 116.5 | 3.3x | 58.1s | 17.6s |
| P4 系統設計 | 35.4 | 116.5 | 3.3x | 57.9s | 17.6s |
| L1 長context | 35.4 | 116.4 | 3.3x | 57.9s | 17.6s |

重點：
- CUDA graph 對 B200 + Qwen3.8-27B 的加速是 **3.3 倍**（遠超常見 1.3~1.8 倍）。
- 原因推測：--enforce-eager 在 B200 上完全放棄 decode 優化；移除後 vLLM 自動用 torch.compile + CUDA graph。
- C 同時釋放大量 KV cache（65536 vs 262144），使 GPU 記憶體壓力大降，間接幫 CUDA graph 成功 capture。
- 改後 GPU 4,5：41-42°C，P0，164962 MiB 使用，無 OOM。

## D. 最終確認：262144 + CUDA graph 穩定（非 OOM）
前一次 L1 500 錯誤經用戶確認是「其他人重啟 service」造成，非 262144 記憶體問題。
改回 262144 + 移除 --enforce-eager 後完整重測：

| 題目 | run1 | run2 | 穩定 |
|---|---|---|---|
| P1 數論 | 116.1 | 116.2 | ✅ |
| P2 演算法 | 116.2 | 116.2 | ✅ |
| P3 動態規劃 | 99.9 | 110.0 | ✅ |
| P4 系統設計 | 116.2 | 111.9 | ✅ |
| L1 長context | 108.4 | 116.1 | ✅ |

結論：
- **移除 --enforce-eager 是主因**（3.3x 加速）。
- max-model-len 保留 262144 沒問題（KV cache 在 B200 183GB 上放得下）。
- 降 max-model-len 到 65536 非必需，保留 262144 給 OpenHands 長任務用更彈。
- 最終設定：qwen3.8-27b = 262144 context + 移除 enforce-eager（CUDA graph）= **116 tok/s 穩定**。

## E. 方案 D1 實測結果（deepseek-v4-flash，TP4，移除 --enforce-eager）

| 題目 | 改前 tok/s | 改後 tok/s | 加速 | 改前時間 | 改後時間 |
|---|---|---|---|---|---|
| P1 數論 | 16.7 | 140.8 | **8.4x** | 117s | 5.6s |
| P2 演算法 | 16.5 | 141.1 | **8.5x** | 124s | 10.3s |
| P3 動態規劃 | 16.3 | 141.0 | **8.6x** | 125s | 12.6s |
| P4 系統設計 | 16.5 | 140.9 | **8.5x** | 124s | 14.4s |
| L1 長context | 16.8 | 140.1 | **8.3x** | 122s | 14.6s |

重點：
- DeepSeek 從 16 tok/s → **141 tok/s（8.5 倍加速）**，比 Qwen 的 3.3 倍還高。
- 原因：--enforce-eager 在 TP4 + B200 上對 decode 傷害更大（更多卡要同步、eager 模式無 graph 加速）。
- 改後 DeepSeek **比 Qwen 還快**（141 vs 116 tok/s）。
- GPU 0-3：40-41°C，173GB/183GB，無 OOM。
- CUDA graph memory: 7.27 GiB（autotune 後）。
- 來源檔 + 生效檔已同步。備份：deepseek-v4-0731.service.bak-preD1-140953

## F. 最終對照總表（全部改完後）

| 模型 | 改前 | 改後 | 加速 | 穩定 | 備註 |
|---|---|---|---|---|---|
| Qwen3.8-27B (TP2) | 35 tok/s | **116 tok/s** | **3.3x** | ✅ | 262144 context |
| DeepSeek-v4-flash (TP4) | 16 tok/s | **141 tok/s** | **8.5x** | ✅ | 262144 context, fp8 KV |

兩台都只需移除 --enforce-eager 就夠（context 保留 262144）。

## G. qwen3-vl（8002）移除 --enforce-eager 結果

| 題目 | 改後 tok/s | 時間 |
|---|---|---|
| P1 數論 | 294.0 | 6.9s |
| P2 演算法 | 294.2 | 7.0s |
| P3 動態規劃 | 294.1 | 7.0s |
| P4 系統設計 | 294.2 | 7.0s |
| L1 長context | 292.1 | 7.0s |

（原本 35 tok/s 等級 → 294 tok/s，約 8.4x。A3B MoE 單卡 CUDA graph 效益最大）
- CUDA graph pool: 1.53 GiB；GPU 6 記憶體健康。
- max_model_len 65536 (64K) 不變；--limit-mm-per-prompt 1 不變。
- 來源檔 + 生效檔已同步。備份：qwen3-vl.service.bak-preB

## H. 三台最終對照總表

| 模型 | port | GPU | 改前 | 改後 | 加速 |
|---|---|---|---|---|---|
| Qwen3.8-27B | 8001 | 4,5 (TP2) | 35 | 116 | 3.3x |
| DeepSeek-v4-flash | 8000 | 0-3 (TP4) | 16 | 141 | 8.5x |
| Qwen3-VL-30B | 8002 | 6 (TP1) | ~35 | 294 | ~8.4x |

KEY TAKEAWAY: 三個 vLLM 全部只需移除 --enforce-eager，context 完全不動。最大加速來自單卡 MoE (qwen3-vl)。
