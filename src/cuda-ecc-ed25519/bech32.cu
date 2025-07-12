#ifndef BECH32_H
#define BECH32_H

#include <string.h>

// Bech32 implementation for GPU
__device__ const char* CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

// Bech32 polymod generator
__device__ uint32_t bech32_polymod(const uint8_t* values, size_t length) {
    uint32_t c = 1;
    for (size_t i = 0; i < length; ++i) {
        uint8_t c0 = c >> 25;
        c = ((c & 0x1ffffff) << 5) ^ values[i];
        if (c0 & 1) c ^= 0x3b6a57b2;
        if (c0 & 2) c ^= 0x26508e6d;
        if (c0 & 4) c ^= 0x1ea119fa;
        if (c0 & 8) c ^= 0x3d4233dd;
        if (c0 & 16) c ^= 0x2a1462b3;
    }
    return c;
}

// Bech32 HRP expand
__device__ void bech32_hrp_expand(const char* hrp, uint8_t* dest) {
    size_t hrp_len = 0;
    while (hrp[hrp_len] != 0) hrp_len++;
    for (size_t i = 0; i < hrp_len; ++i) dest[i] = hrp[i] >> 5;
    dest[hrp_len] = 0;
    for (size_t i = 0; i < hrp_len; ++i) dest[hrp_len + 1 + i] = hrp[i] & 0x1f;
}

// Calculate Bech32 checksum
__device__ void bech32_create_checksum(const char* hrp, const uint8_t* data, size_t data_len, uint8_t* checksum) {
    size_t hrp_len = 0;
    while (hrp[hrp_len] != 0) hrp_len++;
    uint8_t values[1024];
    bech32_hrp_expand(hrp, values);
    size_t values_len = hrp_len * 2 + 1;
    for (size_t i = 0; i < data_len; ++i) values[values_len + i] = data[i];
    for (size_t i = 0; i < 6; ++i) values[values_len + data_len + i] = 0;
    uint32_t polymod = bech32_polymod(values, values_len + data_len + 6) ^ 1;
    for (size_t i = 0; i < 6; ++i) checksum[i] = (polymod >> (5 * (5 - i))) & 0x1f;
}

__device__ bool bech32_encode(char* output, size_t output_len, const char* hrp, const uint8_t* data, size_t data_len) {
    size_t hrp_len = 0;
    while (hrp[hrp_len] != 0) hrp_len++;
    if (output_len < hrp_len + 1 + data_len + 6 + 1) return false;
    size_t pos = 0;
    for (size_t i = 0; i < hrp_len; i++) output[pos++] = hrp[i];
    output[pos++] = '1';
    for (size_t i = 0; i < data_len; i++) output[pos++] = CHARSET[data[i]];
    uint8_t checksum[6];
    bech32_create_checksum(hrp, data, data_len, checksum);
    for (size_t i = 0; i < 6; i++) output[pos++] = CHARSET[checksum[i]];
    output[pos] = 0;
    return true;
}

// Simple function to convert 8-bit bytes to 5-bit bech32 format
__device__ void convert_bits_8_to_5(uint8_t* output, size_t* output_len, const uint8_t* input, size_t input_len) {
    uint32_t acc = 0;
    int bits = 0;
    size_t out_idx = 0;
    const int OUT_BITS = 5;

    for (size_t i = 0; i < input_len; i++) {
        acc = (acc << 8) | input[i];
        bits += 8;

        while (bits >= OUT_BITS) {
            bits -= OUT_BITS;
            output[out_idx++] = (acc >> bits) & 31;
        }
    }

    // Handle remaining bits
    if (bits > 0) {
        output[out_idx++] = (acc << (OUT_BITS - bits)) & 31;
    }

    *output_len = out_idx;
}

// Convert public key to npub format
__device__ bool convert_to_npub(char* output, size_t output_len, const uint8_t* pubkey, size_t pubkey_len) {
    // First convert to 5-bit format
    uint8_t converted[60]; // Enough space for 32 bytes converted to 5-bit
    size_t converted_len = 0;

    convert_bits_8_to_5(converted, &converted_len, pubkey, pubkey_len);

    // Now encode with bech32
    return bech32_encode(output, output_len, "npub", converted, converted_len);
}

#endif // BECH32_H
