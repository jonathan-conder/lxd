#!/usr/bin/env python3
"""Check that PyTorch can compute on the ROCm virtio-gpu device."""

import argparse
import time
from pathlib import Path

import torch

SIZE = 2048
ITERATIONS = 10


def check_matmul():
    a = torch.randn(SIZE, SIZE)
    b = torch.randn(SIZE, SIZE)
    expected = a @ b

    gpu_a = a.cuda()
    gpu_b = b.cuda()
    result = gpu_a @ gpu_b
    torch.cuda.synchronize()

    start = time.perf_counter()
    for _ in range(ITERATIONS):
        result = gpu_a @ gpu_b
    torch.cuda.synchronize()
    elapsed = time.perf_counter() - start

    torch.testing.assert_close(result.cpu(), expected, rtol=1e-3, atol=1e-2)
    tflops = ITERATIONS * 2 * SIZE**3 / elapsed / 1e12
    print(f"fp32 matmul matches CPU: {tflops:.2f} TFLOP/s")


def generate_images(directory, prompt, runs, steps):
    from diffusers import AutoPipelineForText2Image

    pipe = AutoPipelineForText2Image.from_pretrained(
        "stabilityai/sd-turbo", torch_dtype=torch.float16, variant="fp16"
    ).to("cuda")
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)

    def generate(seed):
        generator = torch.Generator("cuda").manual_seed(seed)
        start = time.perf_counter()
        image = pipe(prompt=prompt, num_inference_steps=steps, guidance_scale=0.0, generator=generator).images[0]
        torch.cuda.synchronize()
        elapsed = time.perf_counter() - start
        image.save(directory / f"{seed}.png")
        return elapsed

    print(f"sd-turbo first image: {generate(0):.2f}s")

    times = sorted(generate(seed) for seed in range(1, runs + 1))
    print(f"sd-turbo {runs} images: median {times[runs // 2]:.3f}s, min {times[0]:.3f}s, max {times[-1]:.3f}s")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--images", help="also generate images with sd-turbo and save them in this directory")
    parser.add_argument("--prompt", default="a photo of a red fox in the snow, highly detailed")
    parser.add_argument("--steps", type=int, default=4, help="sd-turbo inference steps (1-4)")
    parser.add_argument("--runs", type=int, default=10, help="timed sd-turbo images after the first")
    args = parser.parse_args()

    if not torch.cuda.is_available():
        raise SystemExit("PyTorch cannot see a ROCm device")

    properties = torch.cuda.get_device_properties(0)
    print(f"torch {torch.__version__}, HIP {torch.version.hip}")
    print(f"device: {properties.name} ({properties.gcnArchName}), {properties.total_memory / 2**30:.1f} GiB")

    check_matmul()

    if args.images:
        generate_images(args.images, args.prompt, args.runs, args.steps)


if __name__ == "__main__":
    main()
