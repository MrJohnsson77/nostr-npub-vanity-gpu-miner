# Nostr npub Vanity GPU Miner

A fast, GPU-accelerated tool for mining Nostr `npub` vanity addresses using CUDA. It brute-forces ED25519 keypairs and finds ones that match your desired patterns, for custom identities like `npub1sats...` or `npub1dev...`.

Built to scratch an itch. Use at your own discretion.

## What does it do?

It generates random ED25519 keypairs and looks for `npub` addresses that match your patterns, using your GPU for maximum speed. Like Bitcoin vanitygen—but for Nostr.

## Features

- **GPU acceleration** – CUDA lets it crank through millions of keypairs per second
- **Multiple pattern support** – Search for several patterns at once
- **Flexible matching** – Match at the start of the `npub` or anywhere inside
- **Wildcard support** – Use `?` as a wildcard in your patterns
- **Live stats** – See current attempts per second and total progress
- **Probably secure-ish** – Uses system entropy and good intentions. Don't trust it with anything you can't lose.
## Configuration Options

Open `src/config.h` to configure the miner behavior:

- **Patterns**: Add your desired patterns to the `patterns[]` array.
  ```cpp
  __device__ static char const *patterns[] = {
      "n0str",
      "n3rd",
      // Add more patterns here
  };
  ```

- **Pattern Matching Mode**:
  - `PREFIX_MATCH_ONLY = 1`: Match patterns only at the beginning of npub (after "npub1")
  - `PREFIX_MATCH_ONLY = 0`: Match patterns anywhere in the npub address

- **Performance Settings**:
  - `ATTEMPTS_PER_EXECUTION`: How many keypairs each GPU thread generates per batch
    - Higher values (10-20 million) work well for modern GPUs like RTX 4090
    - Lower this value (1-5 million) for older GPUs or if experiencing stability issues
  - `MAX_ITERATIONS`: Maximum number of iterations to run
  - `STOP_AFTER_KEYS_FOUND`: Stop mining after finding this many keys

## Installation

### Prerequisites
- NVIDIA GPU with CUDA support
- CUDA toolkit (tested with versions 11.x and 12.x)
- GCC compatible with your CUDA version

### Arch Linux (with distrobox)
```bash
# Create a CUDA development container with NVIDIA support
distrobox create --name cudaenv --image nvidia/cuda:12.3.2-devel-ubuntu22.04 --nvidia
distrobox enter cudaenv

# Inside the container, install necessary packages
sudo apt update
sudo apt install -y build-essential git cmake wget curl gnupg lsb-release gcc-12 g++-12

git clone https://github.com/MrJohnsson77/nostr-npub-vanity-gpu-miner.git
cd nostr-npub-vanity-gpu-miner
export PATH=/usr/local/cuda/bin:$PATH
make -j\$(nproc)
```

### Ubuntu/Debian
```bash
# Install CUDA toolkit and dependencies
sudo apt update
sudo apt install nvidia-cuda-toolkit build-essential build-essential git cmake wget curl gnupg lsb-release gcc-12 g++-12

# Clone and build
git clone https://github.com/MrJohnsson77/nostr-npub-vanity-gpu-miner.git
cd nostr-npub-vanity-gpu-miner
make -j$(nproc)
```

## Running

```bash
LD_LIBRARY_PATH=./release ./release/cuda_ed25519_vanity
```

### Insecure Random Source Handling
By default, if no cryptographically secure random source is available, the program will halt and print an error. If you want to allow fallback to an insecure seed (using the internal clock), you must explicitly pass the `--allow-insecure` flag:

```bash
LD_LIBRARY_PATH=./release ./release/cuda_ed25519_vanity --allow-insecure
```

If you use this flag, the program will print a warning and continue, but any keys generated should **NOT** be used for real cryptographic purposes.

## Example: Saving Output to a Log File

To save all output (including found keys) to a file called `keys.log`, simply pipe the output:

```bash
LD_LIBRARY_PATH=./release ./release/cuda_ed25519_vanity | tee keys.log
```

This will display output in your terminal and also write it to `keys.log` for later review.

## Performance Tips
- Adjust `ATTEMPTS_PER_EXECUTION` for your specific GPU
- Shorter patterns are found much more quickly than longer ones
- A 4-character vanity prefix is ~10-100x easier to find than a 5-character prefix
- For RTX 4090 users: the default settings should work well, but further tuning will probably improve performance (and you know you want to tweak it anyway)

## Output Examples
When a match is found, you will see output like:

```
===== "n3rd" HiT on GPU 0!
nsec: nsec1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
npub: npub1n3rdxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
=====================================================================
```

You'll also see progress information showing:
```
2025-07-12 15:30:45 Iteration 5 Attempts: 51200000000 in 60.531290 at 845678902cps - Total Attempts 256000000000 - keys found 2
```

## Wildcard Pattern Matching
You can use the `?` character as a wildcard in your patterns. This is useful for creating more flexible matches:

```cpp
// Matches "nostr0", "nostr3", "nostrr", etc.
"nostr?"

// Matches any 3-character combination beginning with "a" and ending with "c"
"a?c"
```

# Security Notice

## Key Generation Security
This tool uses a cryptographically secure random number generator (CSPRNG) for key generation:
- **Linux:** Uses `/dev/urandom` for secure randomness
- **Windows:** Uses `CryptGenRandom` via the Windows CryptoAPI
- **macOS:** Uses `/dev/urandom`

**Note:**
- Keys are generated using standard cryptographic methods, but users should review the code and environment before using keys for sensitive or production purposes.
- If running in containers, `/dev/urandom` must be accessible.
- If no secure random source is available, the tool will halt by default. To allow fallback to an insecure seed, use the `--allow-insecure` flag. Insecure seeds are **not safe** for cryptographic use.

No warranties, no liability, no hand-holding. Use at your own risk, or not at all.

# Licensing Notice

This project includes code under multiple open source licenses:

- Parts from [ChorusOne/solanity](https://github.com/ChorusOne/solanity) and [mcf-rocks/solanity](https://github.com/mcf-rocks/solanity) are licensed under the Apache License 2.0.
- Parts from [vikulin/ed25519-gpu-vanity](https://github.com/vikulin/ed25519-gpu-vanity) are licensed under the GNU General Public License (GPL).
- Some components are based on code originally written by Orson Peters, licensed under a permissive MIT-style license (see [`src/cuda-ecc-ed25519/license.txt`](src/cuda-ecc-ed25519/license.txt) for full text).
- Nostr `npub` support and Bech32 encoding added by [MrJohnsson77](https://github.com/MrJohnsson77) are provided under the same license as the project as a whole (GPL), to ensure compatibility with the most restrictive component.

See LICENSE and [`src/cuda-ecc-ed25519/license.txt`](src/cuda-ecc-ed25519/license.txt) for details and original project licenses.
