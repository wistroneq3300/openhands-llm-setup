#!/bin/bash
# 套用 4 個 patch 到 vllm/cute_utils/_tcgen05.py
set -e
python3 << 'PYEOF'
path = '/usr/local/lib/python3.12/dist-packages/vllm/cute_utils/_tcgen05.py'
with open(path, 'r') as f:
    content = f.read()

old_import = 'from cutlass._mlir.dialects import llvm, nvvm, vector'
new_import = old_import + '\nfrom cutlass.experimental.primitives import nvvm_wrapper'
assert old_import in content, 'Patch 1: 找不到 import'
content = content.replace(old_import, new_import, 1)

old_call = 'nvvm.tcgen05_mma_block_scale('
new_call = 'nvvm_wrapper.tcgen05_mma_block_scale('
assert old_call in content, 'Patch 2: 找不到 tcgen05_mma_block_scale'
content = content.replace(old_call, new_call, 1)

old_sym = 'scale_vec_size=nvvm.Tcgen05MMAScaleVecSize.X1'
new_sym = 'scale_vec_size=nvvm_wrapper.Tcgen05MMAScaleVecSize.X1'
assert old_sym in content, 'Patch 3: 找不到 scale_vec_size'
content = content.replace(old_sym, new_sym, 1)

old_block = '''        nvvm_wrapper.tcgen05_mma_block_scale(
            nvvm.Tcgen05MMAKind.MXF8F6F4,
            NVVM_CTA_GROUP_MAP[cta_group],'''
new_block = '''        nvvm_wrapper.tcgen05_mma_block_scale(
            nvvm.Tcgen05MMAKind.MXF8F6F4,
            nvvm_wrapper.CTAGroup[NVVM_CTA_GROUP_MAP[cta_group].name],'''
assert old_block in content, 'Patch 4: 找不到 cta_group block'
content = content.replace(old_block, new_block, 1)

with open(path, 'w') as f:
    f.write(content)
print('✅ 4 個 patch 套用成功')
PYEOF
echo "Patch 完成，開始啟動 vllm..."
exec "$@"
