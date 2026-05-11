# HASH256 GPU Miner - Build Instructions
#
# Requirements:
#   - NVIDIA GPU with CUDA support
#   - CUDA Toolkit 12.0+ (nvcc compiler)
#   - Linux (tested on Ubuntu 22.04)
#
# Build:
#   make
#
# Clean:
#   make clean

NVCC = nvcc
NVCC_FLAGS = -O3 -lineinfo
TARGET = hash256_miner

# Auto-detect GPU architecture (default sm_75 for Turing+)
# Override with: make ARCH=sm_89
ARCH ?= sm_75

# For newer GPUs:
# RTX 3090/3080/3070: sm_86
# RTX 4090/4080/4070: sm_89
# RTX 5090/5080/5070: sm_100

all: $(TARGET)

$(TARGET): miner.cu keccak256.cuh
	$(NVCC) $(NVCC_FLAGS) -arch=$(ARCH) -o $(TARGET) miner.cu

# Build for multiple architectures (slower compile, wider compat)
multi: miner.cu keccak256.cuh
	$(NVCC) $(NVCC_FLAGS) \
		-gencode arch=compute_75,code=sm_75 \
		-gencode arch=compute_86,code=sm_86 \
		-gencode arch=compute_89,code=sm_89 \
		-o $(TARGET) miner.cu

clean:
	rm -f $(TARGET)

.PHONY: all multi clean
