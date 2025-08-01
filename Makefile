OS := $(shell uname)

all:
ifeq ($(OS),Darwin)
SO=dylib
else
SO=so
all: cuda_crypt
endif

V=release

.PHONY:cuda_crypt
cuda_crypt:
	$(MAKE) V=$(V) -C src RELEASE_DIR=../release

DESTDIR ?= dist
install:
	mkdir -p $(DESTDIR)
ifneq ($(OS),Darwin)
	cp -f release/libcuda-crypt.so $(DESTDIR)
endif
	ls -lh $(DESTDIR)

.PHONY:clean
clean:
	$(MAKE) V=$(V) -C src RELEASE_DIR=../release clean
