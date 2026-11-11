#!/usr/bin/env python3
"""Make the 4-bit weight-only GLiClass Edge file from the full-precision ONNX file.

Suite ADR 0004. The upstream 8-bit file (onnx/model_q8.onnx) and ordinary
dynamic 8-bit quantisation both change this model's answers (activations are
rounded too). Weight-only 4-bit (MatMulNBits, block 32, symmetric, compute in
8-bit) keeps every self-test answer within 0.01 of full precision at about a
quarter of the size (1.76 GB -> 0.49 GB). The word table becomes
GatherBlockQuantized. Default opset stays 17: the quantiser raises it to 21,
which breaks this graph's ReduceMax nodes.

  python3 convert.py IN.onnx OUT.onnx
"""
import logging
import os
import sys

os.environ["ORT_DISABLE_TELEMETRY"] = "1"  # see gliclass_edge.py


def main(src: str, dst: str) -> int:
    import onnx
    from onnxruntime.quantization.matmul_nbits_quantizer import (
        DefaultWeightOnlyQuantConfig,
        MatMulNBitsQuantizer,
    )

    logging.disable(logging.INFO)  # the quantiser logs every node at INFO
    ops = ("MatMul", "Gather")
    axes = (("MatMul", 0), ("Gather", 0))
    model = onnx.load(src)
    opset = next(o.version for o in model.opset_import if o.domain in ("", "ai.onnx"))
    cfg = DefaultWeightOnlyQuantConfig(block_size=32, is_symmetric=True, bits=4, accuracy_level=4,
                                       op_types_to_quantize=ops, quant_axes=axes)
    q = MatMulNBitsQuantizer(model, bits=4, block_size=32, is_symmetric=True, accuracy_level=4,
                             op_types_to_quantize=ops, quant_axes=axes, algo_config=cfg)
    q.process()
    out = q.model.model if hasattr(q.model, "model") else q.model
    for o in out.opset_import:
        if o.domain in ("", "ai.onnx"):
            o.version = opset
    counts = {t: sum(1 for n in out.graph.node if n.op_type == t) for t in ("MatMulNBits", "GatherBlockQuantized")}
    if counts["MatMulNBits"] < 144 or counts["GatherBlockQuantized"] != 1:
        print(f"convert: unexpected graph {counts}", file=sys.stderr)
        return 1
    onnx.save_model(out, dst)
    print(f"convert: {counts['MatMulNBits']} weight blocks and the word table now 4-bit")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))
