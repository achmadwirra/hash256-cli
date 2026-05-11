NVCC = nvcc
NVCC_FLAGS = -O3 -use_fast_math --ptxas-options=-v -maxrregcount=64
TARGET = hash256_miner

ARCH ?= sm_75

all: $(TARGET)

$(TARGET): miner.cu keccak256.cuh
	$(NVCC) $(NVCC_FLAGS) -arch=$(ARCH) -o $(TARGET) miner.cu

multi: miner.cu keccak256.cuh
	$(NVCC) $(NVCC_FLAGS) \
		-gencode arch=compute_75,code=sm_75 \
		-gencode arch=compute_86,code=sm_86 \
		-gencode arch=compute_89,code=sm_89 \
		-gencode arch=compute_100,code=sm_100 \
		-o $(TARGET) miner.cu

clean:
	rm -f $(TARGET)

.PHONY: all multi clean
