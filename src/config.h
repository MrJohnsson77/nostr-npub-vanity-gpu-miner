#ifndef VANITY_CONFIG
#define VANITY_CONFIG

// ---- GENERAL SETTINGS ----

// Maximum number of mining iterations to run before stopping
// Each iteration processes ATTEMPTS_PER_EXECUTION * (number of GPU threads)
static int const MAX_ITERATIONS = 100000;

// Stop the miner after finding this many matching keys
static int const STOP_AFTER_KEYS_FOUND = 100;

// ---- GPU PERFORMANCE SETTINGS ----

// How many public keys each GPU thread generates in one batch
// Higher values reduce CPU-GPU communication overhead but use more memory
// For RTX 4090: 10-20 million works well
// For older GPUs: Try 1-5 million if you experience stability issues
__device__ const int ATTEMPTS_PER_EXECUTION = 10000000;

// Maximum number of patterns that can be defined below
__device__ const int MAX_PATTERNS = 10;

// ---- PATTERN MATCHING SETTINGS ----

// Pattern matching mode:
// 1 = Only match at the beginning of npub (after "npub1")
// 0 = Match anywhere in the npub address
__device__ const int PREFIX_MATCH_ONLY = 1;

// ---- PATTERNS TO SEARCH FOR ----
// Add your desired vanity patterns here
// Each pattern is searched for independently
//
// Examples:
// - When PREFIX_MATCH_ONLY=1: "sat" will match "npub1satoshi..."
// - When PREFIX_MATCH_ONLY=0: "sat" could match "npub1abc123sat456..."
//
// You can use '?' as a wildcard for any single character
// For example: "a?c" matches "abc", "a2c", etc.

__device__ static char const *patterns[] = {
      "n0str",
      "n3rd",
    // Add more patterns here, one per line
    // NULL entry is added automatically at the end
};

// ---- DEBUG SETTINGS ----

// Enable performance timing information
// 0 = Disabled, 1 = Enabled
#define ENABLE_TIMING 0

#endif
