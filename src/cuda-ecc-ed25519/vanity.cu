#include <vector>
#include <random>
#include <chrono>
#include <thread>

#include <iostream>
#include <ctime>

#include <assert.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

#include "curand_kernel.h"
#include "ed25519.h"
#include "fixedint.h"
#include "gpu_common.h"
#include "gpu_ctx.h"

#include "keypair.cu"
#include "sc.cu"
#include "fe.cu"
#include "ge.cu"
#include "sha512.cu"
#include "bech32.cu"

// The old, incorrect Bech32 implementation has been removed.
// The code will now correctly use the functions from bech32.cu.

// Include config.h after all other functions are defined
#include "../config.h"

/* -- Types ----------------------------------------------------------------- */

typedef struct {
	// CUDA Random States.
	curandState*    states[8];
} config;

/* -- Prototypes, Because C++ ----------------------------------------------- */

void            vanity_setup(config& vanity, bool allow_insecure);
void            vanity_run(config& vanity);
void __global__ vanity_init(unsigned long long int* seed, curandState* state);
void __global__ vanity_scan(curandState* state, int* keys_found, int* gpu, int* execution_count);
bool __device__ b58enc(char* b58, size_t* b58sz, uint8_t* data, size_t binsz);

/* -- Entry Point ----------------------------------------------------------- */

int main(int argc, char const* argv[]) {
    ed25519_set_verbose(true);

    // Check for --allow-insecure flag
    bool allow_insecure = false;
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--allow-insecure") == 0) {
            allow_insecure = true;
        }
    }

    config vanity;
    vanity_setup(vanity, allow_insecure);
    vanity_run(vanity);
}

// SMITH
std::string getTimeStr(){
    std::time_t now = std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
    std::string s(30, '\0');
    std::strftime(&s[0], s.size(), "%Y-%m-%d %H:%M:%S", std::localtime(&now));
    return s;
}

// SMITH - safe? who knows
unsigned long long int makeSeed(bool allow_insecure = false) {
    unsigned long long int seed = 0;
    bool insecure = false;
    // Try to use random_device for entropy
    try {
        std::random_device rd;
        uint32_t* p_seed = reinterpret_cast<uint32_t*>(&seed);
        for (size_t i = 0; i < sizeof(seed) / sizeof(uint32_t); ++i) {
            p_seed[i] = rd();
        }
    } catch (const std::exception& e) {
        insecure = true;
        std::cerr << "WARNING: Cryptographically secure random_device could not be accessed. Falling back to internal clock for seed generation. Seeds will be very insecure and should NOT be used for real cryptographic purposes!" << std::endl;
    }
    // Mix in high-resolution clock time to protect against a bad random_device
    auto time_seed = std::chrono::high_resolution_clock::now().time_since_epoch().count();
    seed ^= time_seed;
    // Final check: if seed is still 0, just use the time. This should be extremely rare.
    if (seed == 0) {
        seed = time_seed;
    }
    if (insecure && !allow_insecure) {
        std::cerr << "ERROR: Insecure seed source detected and --allow-insecure not set. Aborting." << std::endl;
        exit(1);
    }
    return seed;
}

/* -- Vanity Step Functions ------------------------------------------------- */

void vanity_setup(config &vanity, bool allow_insecure) {
    printf("GPU: Initializing Memory\n");
    int gpuCount = 0;
    cudaGetDeviceCount(&gpuCount);

	// Create random states so kernels have access to random generators
	// while running in the GPU.
	for (int i = 0; i < gpuCount; ++i) {
		cudaSetDevice(i);

		// Fetch Device Properties
		cudaDeviceProp device;
		cudaGetDeviceProperties(&device, i);

		// Calculate Occupancy
		int blockSize       = 0,
		    minGridSize     = 0,
		    maxActiveBlocks = 0;
		cudaOccupancyMaxPotentialBlockSize(&minGridSize, &blockSize, vanity_scan, 0, 0);
		cudaOccupancyMaxActiveBlocksPerMultiprocessor(&maxActiveBlocks, vanity_scan, blockSize, 0);

		// Output Device Details
		// 
		// Our kernels currently don't take advantage of data locality
		// or how warp execution works, so each thread can be thought
		// of as a totally independent thread of execution (bad). On
		// the bright side, this means we can really easily calculate
		// maximum occupancy for a GPU because we don't have to care
		// about building blocks well. Essentially we're trading away
		// GPU SIMD ability for standard parallelism, which CPUs are
		// better at and GPUs suck at.
		//
		// Next Weekend Project: ^ Fix this.
		printf("GPU: %d (%s <%d, %d, %d>) -- W: %d, P: %d, TPB: %d, MTD: (%dx, %dy, %dz), MGS: (%dx, %dy, %dz)\n",
			i,
			device.name,
			blockSize,
			minGridSize,
			maxActiveBlocks,
			device.warpSize,
			device.multiProcessorCount,
		       	device.maxThreadsPerBlock,
			device.maxThreadsDim[0],
			device.maxThreadsDim[1],
			device.maxThreadsDim[2],
			device.maxGridSize[0],
			device.maxGridSize[1],
			device.maxGridSize[2]
		);

                // the random number seed is uniquely generated each time the program 
                // is run, from the operating system entropy

		unsigned long long int rseed = makeSeed(allow_insecure);
		printf("Initialising from entropy: %llu\n",rseed);

		unsigned long long int* dev_rseed;
	        cudaMalloc((void**)&dev_rseed, sizeof(unsigned long long int));		
                cudaMemcpy( dev_rseed, &rseed, sizeof(unsigned long long int), cudaMemcpyHostToDevice ); 

		cudaMalloc((void **)&(vanity.states[i]), maxActiveBlocks * blockSize * sizeof(curandState));
		vanity_init<<<maxActiveBlocks, blockSize>>>(dev_rseed, vanity.states[i]);
	}

	printf("END: Initializing Memory\n");
}

void vanity_run(config &vanity) {
	int gpuCount = 0;
	cudaGetDeviceCount(&gpuCount);

	unsigned long long int  executions_total = 0; 
	unsigned long long int  executions_this_iteration; 
	int  executions_this_gpu; 
        int* dev_executions_this_gpu[100];

        int  keys_found_total = 0;
        int  keys_found_this_iteration;
        int* dev_keys_found[100]; // not more than 100 GPUs ok!

	// RTX 4090 optimization - these values work well for high-end GPUs
	// You can experiment with these values to find the optimal configuration
	int threadsPerBlock = 256; // 256 threads per block is often optimal
	int blocksPerGrid = 8192; // For RTX 4090, this provides good occupancy

	for (int i = 0; i < MAX_ITERATIONS; ++i) {
		auto start  = std::chrono::high_resolution_clock::now();

                executions_this_iteration=0;

		// Run on all GPUs
		for (int g = 0; g < gpuCount; ++g) {
			cudaSetDevice(g);

			// For RTX 4090, we're using fixed block/grid size for better performance
			// Comment out the auto-calculation for better performance
			/*
			// Calculate Occupancy
			int blockSize       = 0,
			    minGridSize     = 0,
			    maxActiveBlocks = 0;
			cudaOccupancyMaxPotentialBlockSize(&minGridSize, &blockSize, vanity_scan, 0, 0);
			cudaOccupancyMaxActiveBlocksPerMultiprocessor(&maxActiveBlocks, vanity_scan, blockSize, 0);
			*/

			int* dev_g;
	                cudaMalloc((void**)&dev_g, sizeof(int));
                	cudaMemcpy( dev_g, &g, sizeof(int), cudaMemcpyHostToDevice ); 

	                cudaMalloc((void**)&dev_keys_found[g], sizeof(int));		
	                cudaMalloc((void**)&dev_executions_this_gpu[g], sizeof(int));		

			// Use our optimized thread/block config for RTX 4090
			vanity_scan<<<blocksPerGrid, threadsPerBlock>>>(vanity.states[g], dev_keys_found[g], dev_g, dev_executions_this_gpu[g]);

		}

		// Print progress while waiting for the kernel to finish, as it can take a while.
		cudaError_t err;
		do {
			// Don't print a message on every check, just sleep.
			std::this_thread::sleep_for(std::chrono::seconds(60));
			err = cudaStreamQuery(0);
			if (err == cudaErrorNotReady) {
				printf("Still working on a large batch of keys... please wait.\n");
				fflush(stdout);
			}
		} while (err == cudaErrorNotReady);


		// Synchronize while we wait for kernels to complete.
		cudaDeviceSynchronize();
		auto finish = std::chrono::high_resolution_clock::now();

		for (int g = 0; g < gpuCount; ++g) {
                	cudaMemcpy( &keys_found_this_iteration, dev_keys_found[g], sizeof(int), cudaMemcpyDeviceToHost ); 
                	keys_found_total += keys_found_this_iteration; 
			//printf("GPU %d found %d keys\n",g,keys_found_this_iteration);

                	cudaMemcpy( &executions_this_gpu, dev_executions_this_gpu[g], sizeof(int), cudaMemcpyDeviceToHost ); 
                	executions_this_iteration += executions_this_gpu * ATTEMPTS_PER_EXECUTION; 
                	executions_total += executions_this_gpu * ATTEMPTS_PER_EXECUTION; 
                        //printf("GPU %d executions: %d\n",g,executions_this_gpu);
		}

		// Print out performance Summary
		std::chrono::duration<double> elapsed = finish - start;
		printf("%s Iteration %d Attempts: %llu in %f at %fcps - Total Attempts %llu - keys found %d\n",
			getTimeStr().c_str(),
			i+1,
			executions_this_iteration,
			elapsed.count(),
			executions_this_iteration / elapsed.count(),
			executions_total,
			keys_found_total
		);

                if ( keys_found_total >= STOP_AFTER_KEYS_FOUND ) {
                	printf("Enough keys found, Done! \n");
		        exit(0);	
		}	
	}

	printf("Iterations complete, Done!\n");
}

/* -- CUDA Vanity Functions ------------------------------------------------- */

void __global__ vanity_init(unsigned long long int* rseed, curandState* state) {
	int id = threadIdx.x + (blockIdx.x * blockDim.x);  
	curand_init(*rseed + id, id, 0, &state[id]);
}

void __global__ vanity_scan(curandState* state, int* keys_found, int* gpu, int* exec_count) {
	int id = threadIdx.x + (blockIdx.x * blockDim.x);

        atomicAdd(exec_count, 1);

	// Count patterns and calculate pattern lengths more safely
    	int pattern_lengths[MAX_PATTERNS] = {0}; // Initialize all to 0
	int pattern_count = 0;

	// Count valid patterns (non-empty strings) and calculate their lengths
	for (int n = 0; n < MAX_PATTERNS; ++n) {
		// Check if we've reached the end of the patterns array
		if (patterns[n] == NULL) {
			break;
		}

		// Calculate pattern length safely
		int letter_count = 0;
		while (patterns[n][letter_count] != 0 && letter_count < 100) { // Prevent infinite loop with max length
			letter_count++;
		}

		// Only count non-empty patterns
		if (letter_count > 0) {
			pattern_lengths[n] = letter_count;
			pattern_count++;
		}
	}

	// Safety check - if no valid patterns found, return early
	if (pattern_count == 0 && id == 0) {
		printf("ERROR: No valid patterns defined in config.h\n");
		return;
	}

	// Local Kernel State
	ge_p3 A;
	curandState localState     = state[id];
	unsigned char seed[32]     = {0};
	unsigned char publick[32]  = {0};
	unsigned char privatek[64] = {0};
	char npub[100]             = {0}; // Buffer for bech32 encoded npub

	// Start from an Initial Random Seed
	for (int i = 0; i < 32; ++i) {
		float random    = curand_uniform(&localState);
		uint8_t keybyte = (uint8_t)(random * 255);
		seed[i]         = keybyte;
	}

	// Generate Random Key Data
	sha512_context md;

	// Thread 0 prints the patterns we're searching for
	if (id == 0) {
		if (PREFIX_MATCH_ONLY) {
			printf("\nSearching for prefixes in npub addresses: ");
		} else {
			printf("\nSearching for patterns in npub addresses: ");
		}
		for (unsigned int n = 0; n < sizeof(patterns) / sizeof(patterns[0]); ++n) {
			if (pattern_lengths[n] > 0) {
				printf("\"%s\" ", patterns[n]);
			}
		}
		printf("\n\n");
	}

	// Every few threads will report progress
	// bool is_reporter_thread = (id % 100 == 0);
	// unsigned int report_interval = ATTEMPTS_PER_EXECUTION / 10; // Report 10 times during execution

	for (int attempts = 0; attempts < ATTEMPTS_PER_EXECUTION; ++attempts) {
		// Print progress for reporter threads
		// if (is_reporter_thread && attempts % report_interval == 0) {
		// 	printf("GPU %d Thread %d: %d/%d attempts completed (%.1f%%)\n",
		// 		*gpu, id, attempts, ATTEMPTS_PER_EXECUTION,
		// 		(float)attempts / ATTEMPTS_PER_EXECUTION * 100.0f);
		// }

		// sha512_init Inlined
		md.curlen   = 0;
		md.length   = 0;
		md.state[0] = UINT64_C(0x6a09e667f3bcc908);
		md.state[1] = UINT64_C(0xbb67ae8584caa73b);
		md.state[2] = UINT64_C(0x3c6ef372fe94f82b);
		md.state[3] = UINT64_C(0xa54ff53a5f1d36f1);
		md.state[4] = UINT64_C(0x510e527fade682d1);
		md.state[5] = UINT64_C(0x9b05688c2b3e6c1f);
		md.state[6] = UINT64_C(0x1f83d9abfb41bd6b);
		md.state[7] = UINT64_C(0x5be0cd19137e2179);

		// sha512_update inlined
		// 
		// All `if` statements from this function are eliminated if we
		// will only ever hash a 32 byte seed input. So inlining this
		// has a drastic speed improvement on GPUs.
		//
		// This means:
		//   * Normally we iterate for each 128 bytes of input, but we are always < 128. So no iteration.
		//   * We can eliminate a MIN(inlen, (128 - md.curlen)) comparison, specialize to 32, branch prediction improvement.
		//   * We can eliminate the in/inlen tracking as we will never subtract while under 128
		//   * As a result, the only thing update does is copy the bytes into the buffer.
		const unsigned char *in = seed;
		for (size_t i = 0; i < 32; i++) {
			md.buf[i + md.curlen] = in[i];
		}
		md.curlen += 32;


		// sha512_final inlined
		// 
		// As update was effectively elimiated, the only time we do
		// sha512_compress now is in the finalize function. We can also
		// optimize this:
		//
		// This means:
		//   * We don't need to care about the curlen > 112 check. Eliminating a branch.
		//   * We only need to run one round of sha512_compress, so we can inline it entirely as we don't need to unroll.
		md.length += md.curlen * UINT64_C(8);
		md.buf[md.curlen++] = (unsigned char)0x80;

		while (md.curlen < 120) {
			md.buf[md.curlen++] = (unsigned char)0;
		}

		STORE64H(md.length, md.buf+120);

		// Inline sha512_compress
		uint64_t S[8], W[80], t0, t1;
		int i;

		/* Copy state into S */
		for (i = 0; i < 8; i++) {
			S[i] = md.state[i];
		}

		/* Copy the state into 1024-bits into W[0..15] */
		for (i = 0; i < 16; i++) {
			LOAD64H(W[i], md.buf + (8*i));
		}

		/* Fill W[16..79] */
		for (i = 16; i < 80; i++) {
			W[i] = Gamma1(W[i - 2]) + W[i - 7] + Gamma0(W[i - 15]) + W[i - 16];
		}

		/* Compress */
		#define RND(a,b,c,d,e,f,g,h,i) \
		t0 = h + Sigma1(e) + Ch(e, f, g) + K[i] + W[i]; \
		t1 = Sigma0(a) + Maj(a, b, c);\
		d += t0; \
		h  = t0 + t1;

		for (i = 0; i < 80; i += 8) {
			RND(S[0],S[1],S[2],S[3],S[4],S[5],S[6],S[7],i+0);
			RND(S[7],S[0],S[1],S[2],S[3],S[4],S[5],S[6],i+1);
			RND(S[6],S[7],S[0],S[1],S[2],S[3],S[4],S[5],i+2);
			RND(S[5],S[6],S[7],S[0],S[1],S[2],S[3],S[4],i+3);
			RND(S[4],S[5],S[6],S[7],S[0],S[1],S[2],S[3],i+4);
		 RND(S[3],S[4],S[5],S[6],S[7],S[0],S[1],S[2],i+5);
			RND(S[2],S[3],S[4],S[5],S[6],S[7],S[0],S[1],i+6);
			RND(S[1],S[2],S[3],S[4],S[5],S[6],S[7],S[0],i+7);
		}

		#undef RND

		/* Feedback */
		for (i = 0; i < 8; i++) {
			md.state[i] = md.state[i] + S[i];
		}

		// We can now output our finalized bytes into the output buffer.
		for (i = 0; i < 8; i++) {
			STORE64H(md.state[i], privatek+(8*i));
		}

		// Code Until here runs at 87_000_000H/s.

		// ed25519 Hash Clamping
		privatek[0]  &= 248;
		privatek[31] &= 63;
		privatek[31] |= 64;

		// ed25519 curve multiplication to extract a public key.
		ge_scalarmult_base(&A, privatek);
		ge_p3_tobytes(publick, &A);

		// Convert the public key to npub format
		uint8_t converted[60];
		size_t converted_len = 0;
		convert_bits_8_to_5(converted, &converted_len, publick, 32);
		bech32_encode(npub, sizeof(npub), "npub", converted, converted_len);

		// Search for patterns in the npub string
		for (int i = 0; i < sizeof(patterns) / sizeof(patterns[0]); ++i) {
			// Skip empty pattern entries
			if (pattern_lengths[i] == 0) continue;

			// Get the length of the npub string
			int npub_len = 0;
			while (npub[npub_len] != 0 && npub_len < sizeof(npub)) {
				npub_len++;
			}

			// Determine search range based on PREFIX_MATCH_ONLY setting
			int max_start_pos = PREFIX_MATCH_ONLY ? 5 : (npub_len - pattern_lengths[i]);
			int min_start_pos = PREFIX_MATCH_ONLY ? 5 : 0;  // Start at position 5 for prefix match (after "npub1")

			// Check for matches in the npub string
			for (int start = min_start_pos; start <= max_start_pos; start++) {
				bool matched = true;
				for (int j = 0; j < pattern_lengths[i]; ++j) {
					// Check if current character matches the pattern
					// '?' is treated as a wildcard character
					if (patterns[i][j] != '?' && npub[start + j] != patterns[i][j]) {
						matched = false;
						break;
					}
				}

				if (matched) {
					atomicAdd(keys_found, 1);

					// Calculate and display nsec for reference
					char nsec[100] = {0};
					uint8_t nsec_converted[60];
					size_t nsec_converted_len = 0;
					convert_bits_8_to_5(nsec_converted, &nsec_converted_len, seed, 32);
					bech32_encode(nsec, sizeof(nsec), "nsec", nsec_converted, nsec_converted_len);

					printf("===== \"%s\" HiT on GPU %d!\n", patterns[i], *gpu);
					printf("nsec: %s\n", nsec);
					printf("npub: %s\n", npub);
					printf("=====================================================================\n\n");
					break;
				}
			}
		}

		// Increment Seed.
		for (int i = 0; i < 32; ++i) {
			if (seed[i] == 255) {
				seed[i]  = 0;
			} else {
				seed[i] += 1;
				break;
			}
		}
	}

	// Copy Random State so that future calls of this kernel/thread/block
	// don't repeat their sequences.
	state[id] = localState;
}

bool __device__ b58enc(
	char    *b58,
       	size_t  *b58sz,
       	uint8_t *data,
       	size_t  binsz
) {
	// Base58 Lookup Table
	const char b58digits_ordered[] = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

	const uint8_t *bin = data;
	int carry;
	size_t i, j, high, zcount = 0;
	size_t size;
	
	while (zcount < binsz && !bin[zcount])
		++zcount;
	
	size = (binsz - zcount) * 138 / 100 + 1;
	uint8_t buf[256];
	memset(buf, 0, size);
	
	for (i = zcount, high = size - 1; i < binsz; ++i, high = j)
	{
		for (carry = bin[i], j = size - 1; (j > high) || carry; --j)
		{
			carry += 256 * buf[j];
			buf[j] = carry % 58;
			carry /= 58;
			if (!j) {
				// Otherwise j wraps to maxint which is > high
				break;
			}
		}
	}
	
	for (j = 0; j < size && !buf[j]; ++j);
	
	if (*b58sz <= zcount + size - j) {
		*b58sz = zcount + size - j + 1;
		return false;
	}
	
	if (zcount) memset(b58, '1', zcount);
	for (i = zcount; j < size; ++i, ++j) b58[i] = b58digits_ordered[buf[j]];

	b58[i] = '\0';
	*b58sz = i + 1;
	
	return true;
}
