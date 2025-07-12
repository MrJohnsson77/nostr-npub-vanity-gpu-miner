#
#  Makefile for ed25519-gpu-vanity (Nostr GPU npub vanity miner)
#
#  This Makefile builds the CUDA-based miner for Nostr npub vanity public keys (ED25519).
#  It uses only the necessary CUDA sources for key generation and Bech32 encoding.
#
#  By default, builds the release version (V=release). Override with V=debug for debug builds.
#
#  Output binary: release/cuda_ed25519_vanity
#
#  Requirements:
#    - CUDA toolkit (nvcc)
#    - Compatible GCC version for CUDA
#    - Linux, Windows, or macOS (see README for platform notes)
#
#  Usage:
#    make            # Builds release/cuda_ed25519_vanity
#    make clean      # Removes build artifacts
#    V=debug make    # Builds debug version
#
#  See README.md for installation, configuration, and security notes.
#
#  NO WARRANTY OR LIABILITY WHATSOEVER. USE AT YOUR OWN RISK.
#

# Set default build type to release if not specified
V ?= release
RELEASE_DIR ?= ../release
include gpu-common.mk

ECC_SCAN_BIN=cuda_ed25519_vanity
LIB=cuda-crypt

CUDA_HEADER_DIR:=cuda-headers
CFLAGS+=-DENDIAN_NEUTRAL -DLTC_NO_ASM -I$(CUDA_HEADER_DIR)

all: $(RELEASE_DIR)/$(ECC_SCAN_BIN)

ECC_DIR:=cuda-ecc-ed25519

KEYPAIR_SRCS:=$(addprefix $(ECC_DIR)/,keypair.cu ed25519.h ge.h)
$(RELEASE_DIR)/keypair.o: $(KEYPAIR_SRCS)
	@mkdir -p $(@D)
	$(NVCC) -rdc=true $(CFLAGS) -c $< -o $@

SEED_SRCS:=$(addprefix $(ECC_DIR)/,seed.cu ed25519.h)
$(RELEASE_DIR)/seed.o: $(SEED_SRCS)
	@mkdir -p $(@D)
	$(NVCC) -rdc=true $(CFLAGS) -c $< -o $@

SIGN_SRCS:=$(addprefix $(ECC_DIR)/,sign.cu sha512.h ge.h sc.h fe.cu ../$(CUDA_HEADER_DIR)/gpu_common.h ed25519.h)
$(RELEASE_DIR)/sign.o: $(SIGN_SRCS)
	@mkdir -p $(@D)
	$(NVCC) -rdc=true $(CFLAGS) -c $< -o $@

VERIFY_SRCS:=$(addprefix $(ECC_DIR)/,verify.cu sha512.cu ge.cu sc.cu fe.cu keypair.cu common.cu ed25519.h)
$(RELEASE_DIR)/verify.o: $(VERIFY_SRCS)
	@mkdir -p $(@D)
	$(NVCC) -rdc=true $(CFLAGS) -c $< -o $@

$(RELEASE_DIR)/gpu_ctx.o: $(addprefix $(ECC_DIR)/,gpu_ctx.cu gpu_ctx.h)
	@mkdir -p $(@D)
	$(NVCC) -rdc=true $(CFLAGS) -c $< -o $@

$(RELEASE_DIR)/ecc_scan.o: $(addprefix $(ECC_DIR)/,vanity.cu ed25519.h)
	@mkdir -p $(@D)
	$(NVCC) -rdc=true $(CFLAGS) -c $< -o $@

CPU_GPU_OBJS=$(addprefix $(RELEASE_DIR)/,verify.o gpu_ctx.o sign.o seed.o keypair.o)

$(RELEASE_DIR)/crypt-dlink.o: $(CPU_GPU_OBJS)
	$(NVCC) -Xcompiler "-fPIC" $(CFLAGS) --device-link $^ --output-file $@

$(RELEASE_DIR)/lib$(LIB).so: $(RELEASE_DIR)/crypt-dlink.o $(CPU_GPU_OBJS)
	$(NVCC) -Xcompiler "-fPIC" --shared --output-file $@ $^

$(RELEASE_DIR)/$(ECC_SCAN_BIN): $(RELEASE_DIR)/ecc_scan.o $(RELEASE_DIR)/lib$(LIB).so
	$(NVCC) $(CFLAGS) -L$(RELEASE_DIR) -l$(LIB) $< -o $@

.PHONY:clean
clean:
	rm -rf $(RELEASE_DIR)
