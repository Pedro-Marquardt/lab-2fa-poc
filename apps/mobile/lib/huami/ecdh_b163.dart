import 'dart:typed_data';

/// Port of Gadgetbridge `ECDH_B163` (tiny-ECDH, NIST B-163).
/// Used by Mi Band+ Huami New Auth Protocol.
class EcdhB163 {
  EcdhB163._();

static const int CURVE_DEGREE = 163;
    static const int ECC_PRV_KEY_SIZE = 24;
    static const int ECC_PUB_KEY_SIZE = 2 * ECC_PRV_KEY_SIZE;

    /* margin for overhead needed in intermediate calculations */
    static const int BITVEC_MARGIN = 3;
    static const int BITVEC_NBITS = (CURVE_DEGREE + BITVEC_MARGIN);
    static const int BITVEC_NWORDS = ((BITVEC_NBITS + 31) ~/ 32);
    static const int BITVEC_NBYTES = (4 * BITVEC_NWORDS);

    /******************************************************************************/

    /* Here the curve parameters are defined. */

    /* NIST B-163 */
    static final List<int> polynomial = <int>[0x000000c9, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000008];
    static final List<int> coeff_b = <int>[0x4a3205fd, 0x512f7874, 0x1481eb10, 0xb8c953ca, 0x0a601907, 0x00000002];
    static final List<int> base_x = <int>[0xe8343e36, 0xd4994637, 0xa0991168, 0x86a2d57e, 0xf0eba162, 0x00000003];
    static final List<int> base_y = <int>[0x797324f1, 0xb11c5c0c, 0xa2cdd545, 0x71a0094f, 0xd51fbc6c, 0x00000000];
    static final List<int> base_order = <int>[0xa4234c33, 0x77e70c12, 0x000292fe, 0x00000000, 0x00000000, 0x00000004];

    /*************************************************************************************************/

    /* Private / static functions: */

    /// Force Java-like uint32 (Dart ints are arbitrary precision).
    static int _u32(int v) => v & 0xffffffff;

    /* some basic bit-manipulation routines that act on bit-vectors follow */
    static int bitvec_get_bit(List<int> x, int idx) {
        return (_u32(x[idx ~/ 32]) >> (idx & 31)) & 1;
    }

    static void bitvec_clr_bit(List<int> x, int idx) {
        x[idx ~/ 32] = _u32(x[idx ~/ 32] & ~(1 << (idx & 31)));
    }

    static void bitvec_copy(List<int> x, List<int> y) {
        for (var i = 0; i < BITVEC_NWORDS; ++i) {
            x[i] = _u32(y[i]);
        }
    }

    static void bitvec_swap(List<int> x, List<int> y) {
        final tmp = List<int>.filled(BITVEC_NWORDS, 0);
        bitvec_copy(tmp, x);
        bitvec_copy(x, y);
        bitvec_copy(y, tmp);
    }

    static bool bitvec_equal(List<int> x, List<int> y) {
        for (var i = 0; i < BITVEC_NWORDS; ++i) {
            if (_u32(x[i]) != _u32(y[i])) return false;
        }
        return true;
    }

    static void bitvec_set_zero(List<int> x) {
        for (var i = 0; i < BITVEC_NWORDS; ++i) {
            x[i] = 0;
        }
    }

    static bool bitvec_is_zero(List<int> x) {
        for (var i = 0; i < BITVEC_NWORDS; ++i) {
            if (_u32(x[i]) != 0) return false;
        }
        return true;
    }

    static int bitvec_degree(List<int> x) {
        var i = BITVEC_NWORDS * 32;
        var y = BITVEC_NWORDS;
        while ((i > 0) && (_u32(x[--y]) == 0)) {
            i -= 32;
        }
        if (i != 0) {
            var u32mask = 0x80000000;
            while ((_u32(x[y]) & u32mask) == 0) {
                u32mask >>= 1;
                i -= 1;
            }
        }
        return i;
    }

    static void bitvec_lshift(List<int> x, List<int> y, int nbits) {
        final nwords = nbits ~/ 32;
        var i = 0;
        for (; i < nwords; ++i) {
            x[i] = 0;
        }
        var j = 0;
        while (i < BITVEC_NWORDS) {
            x[i] = _u32(y[j]);
            i += 1;
            j += 1;
        }

        nbits &= 31;
        if (nbits != 0) {
            for (i = BITVEC_NWORDS - 1; i > 0; --i) {
                x[i] = _u32((_u32(x[i]) << nbits) | (_u32(x[i - 1]) >> (32 - nbits)));
            }
            x[0] = _u32(_u32(x[0]) << nbits);
        }
    }

    /*************************************************************************************************/
    /*
     * Code that does arithmetic on bit-vectors in the Galois Field
     * GF(2^CURVE_DEGREE).
     */

    /*************************************************************************************************/

    static void gf2field_set_one(List<int> x) {
        /* Set first word to one */
        x[0] = 1;
        /* .. and the rest to zero */
        int i;
        for (i = 1; i < BITVEC_NWORDS; ++i) {
            x[i] = 0;
        }
    }


    /* fastest check if x == 1 */
    static bool gf2field_is_one(List<int> x) {
        /* Check if first word == 1 */
        if (_u32(x[0]) != 1) {
            return false;
        }
        int i;
        for (i = 1; i < BITVEC_NWORDS; ++i) {
            if (_u32(x[i]) != 0) {
                break;
            }
        }
        return (i == BITVEC_NWORDS);
    }

    /* galois field(2^m) addition is modulo 2, so XOR is used instead - 'z := a + b' */
    static void gf2field_add(List<int> z, List<int> x, List<int> y) {
        for (var i = 0; i < BITVEC_NWORDS; ++i) {
            z[i] = _u32(x[i] ^ y[i]);
        }
    }

    /* increment element */
    static void gf2field_inc(List<int> x) {
        x[0] ^= 1;
    }

    /* field multiplication 'z := (x * y)' */
    static void gf2field_mul(List<int> z, List<int> x, List<int> y) {
        int i;
        List<int> tmp = List<int>.filled(BITVEC_NWORDS, 0);
        assert(z != y);

        bitvec_copy(tmp, x);

        /* LSB set? Then start with x */
        if (bitvec_get_bit(y, 0) != 0) {
            bitvec_copy(z, x);
        } else /* .. or else start with zero */ {
            bitvec_set_zero(z);
        }

        /* Then add 2^i * x for the rest */
        for (i = 1; i < CURVE_DEGREE; ++i) {
            /* lshift 1 - doubling the value of tmp */
            bitvec_lshift(tmp, tmp, 1);

            /* Modulo reduction polynomial if degree(tmp) > CURVE_DEGREE */
            if (bitvec_get_bit(tmp, CURVE_DEGREE) != 0) {
                gf2field_add(tmp, tmp, polynomial);
            }

            /* Add 2^i * tmp if this factor in y is non-zero */
            if (bitvec_get_bit(y, i) != 0) {
                gf2field_add(z, z, tmp);
            }
        }
    }

    /* field inversion 'z := 1/x' */
    static void gf2field_inv(List<int> z, List<int> x) {
        List<int> u = List<int>.filled(BITVEC_NWORDS, 0);
        List<int> v = List<int>.filled(BITVEC_NWORDS, 0);
        List<int> g = List<int>.filled(BITVEC_NWORDS, 0);
        List<int> h = List<int>.filled(BITVEC_NWORDS, 0);

        int i;

        bitvec_copy(u, x);
        bitvec_copy(v, polynomial);
        bitvec_set_zero(g);
        gf2field_set_one(z);

        while (!gf2field_is_one(u)) {
            i = (bitvec_degree(u) - bitvec_degree(v));

            if (i < 0) {
                bitvec_swap(u, v);
                bitvec_swap(g, z);
                i = -i;
            }
            bitvec_lshift(h, v, i);
            gf2field_add(u, u, h);
            bitvec_lshift(h, g, i);
            gf2field_add(z, z, h);
        }
    }

    /*************************************************************************************************/
    /*
     * The following code takes care of Galois-Field arithmetic.
     * Elliptic curve points are represented by pairs (x,y) of bitvec_t.
     * It is assumed that curve coefficient 'a' is {0,1}
     * This is the case for all NIST binary curves.
     * Coefficient 'b' is given in 'coeff_b'.
     * '(base_x, base_y)' is a point that generates a large prime order group.
     */

    /*************************************************************************************************/


    static void gf2point_copy(List<int> x1, List<int> y1, List<int> x2, List<int> y2) {
        bitvec_copy(x1, x2);
        bitvec_copy(y1, y2);
    }

    static void gf2point_set_zero(List<int> x, List<int> y) {
        bitvec_set_zero(x);
        bitvec_set_zero(y);
    }

    static bool gf2point_is_zero(List<int> x, List<int> y) {
        return (bitvec_is_zero(x)
                && bitvec_is_zero(y));
    }

    /* double the point (x,y) */
    static void gf2point_double(List<int> x, List<int> y) {
        /* iff P = O (zero or infinity): 2 * P = P */
        if (bitvec_is_zero(x)) {
            bitvec_set_zero(y);
        } else {
            List<int> l = List<int>.filled(BITVEC_NWORDS, 0);
            gf2field_inv(l, x);
            gf2field_mul(l, l, y);
            gf2field_add(l, l, x);
            gf2field_mul(y, x, x);
            gf2field_mul(x, l, l);
            gf2field_inc(l);
            gf2field_add(x, x, l);
            gf2field_mul(l, l, x);
            gf2field_add(y, y, l);
        }
    }

    /* add two points together (x1, y1) := (x1, y1) + (x2, y2) */
    static void gf2point_add(List<int> x1, List<int> y1, List<int> x2, List<int> y2) {
        if (!gf2point_is_zero(x2, y2)) {
            if (gf2point_is_zero(x1, y1)) {
                gf2point_copy(x1, y1, x2, y2);
            } else {
                if (bitvec_equal(x1, x2)) {
                    if (bitvec_equal(y1, y2)) {
                        gf2point_double(x1, y1);
                    } else {
                        gf2point_set_zero(x1, y1);
                    }
                } else {
                    /* Arithmetic with temporary variables */
                    List<int> a = List<int>.filled(BITVEC_NWORDS, 0);
                    List<int> b = List<int>.filled(BITVEC_NWORDS, 0);
                    List<int> c = List<int>.filled(BITVEC_NWORDS, 0);
                    List<int> d = List<int>.filled(BITVEC_NWORDS, 0);

                    gf2field_add(a, y1, y2);
                    gf2field_add(b, x1, x2);
                    gf2field_inv(c, b);
                    gf2field_mul(c, c, a);
                    gf2field_mul(d, c, c);
                    gf2field_add(d, d, c);
                    gf2field_add(d, d, b);
                    gf2field_inc(d);
                    gf2field_add(x1, x1, d);
                    gf2field_mul(a, x1, c);
                    gf2field_add(a, a, d);
                    gf2field_add(y1, y1, a);
                    bitvec_copy(x1, d);
                }
            }
        }
    }


    /* point multiplication via double-and-add algorithm */
    static void gf2point_mul(List<int> x, List<int> y, List<int> exp) {
        List<int> tmpx = List<int>.filled(BITVEC_NWORDS, 0);
        List<int> tmpy = List<int>.filled(BITVEC_NWORDS, 0);

        int i;
        int nbits = bitvec_degree(exp);
        gf2point_set_zero(tmpx, tmpy);

        for (i = (nbits - 1); i >= 0; --i) {
            gf2point_double(tmpx, tmpy);

            if (bitvec_get_bit(exp, i) != 0) {
                gf2point_add(tmpx, tmpy, x, y);
            }
        }

        gf2point_copy(x, y, tmpx, tmpy);
    }


    /* check if y^2 + x*y = x^3 + a*x^2 + coeff_b holds */
    static bool gf2point_on_curve(List<int> x, List<int> y) {
        List<int> a = List<int>.filled(BITVEC_NWORDS, 0);
        List<int> b = List<int>.filled(BITVEC_NWORDS, 0);

        if (gf2point_is_zero(x, y)) {
            return false;
        } else {
            gf2field_mul(a, x, x);
            gf2field_mul(b, a, x);
            gf2field_add(a, a, b);
            gf2field_add(a, a, coeff_b);
            gf2field_mul(b, y, y);
            gf2field_add(a, a, b);
            gf2field_mul(b, x, y);

            return bitvec_equal(a, b);
        }
    }

    // helper needed for C->Java conversion (Java cant cast pointers)
    static List<int> bytes_to_int(Uint8List bytes, int offset) {
        List<int> value = List<int>.filled(BITVEC_NWORDS, 0);
        int byteptr = offset;
        for (int i = 0; i < BITVEC_NWORDS; i++) {
            value[i] = _u32(((bytes[byteptr++] & 0xff)) | ((bytes[byteptr++] & 0xff) << 8) | ((bytes[byteptr++] & 0xff) << 16) | ((bytes[byteptr++] & 0xff) << 24));
        }
        return value;
    }

    // helper needed for C->Java conversion (Java cant cast pointers)
    static void ints_to_bytes(Uint8List bytes, List<int> ints, int offset) {
        int byteptr = offset;
        for (int i = 0; i < BITVEC_NWORDS; i++) {
            final w = _u32(ints[i]);
            bytes[byteptr++] = w & 0xff;
            bytes[byteptr++] = (w >> 8) & 0xff;
            bytes[byteptr++] = (w >> 16) & 0xff;
            bytes[byteptr++] = (w >> 24) & 0xff;
        }
    }

    /*************************************************************************************************/
    /*
     * Elliptic Curve Diffie-Hellman key exchange protocol.
     */

    /*************************************************************************************************/

    /* NOTE: should contain random data a-priori! */
    static bool ecdh_generate_keys(Uint8List public_key, Uint8List private_key) {
        List<int> private_key_int32 = bytes_to_int(private_key, 0);
        List<int> public_key_int32_1 = bytes_to_int(public_key, 0);
        List<int> public_key_int32_2 = bytes_to_int(public_key, BITVEC_NBYTES);
        /* Get copy of "base" point 'G' */
        gf2point_copy(public_key_int32_1, public_key_int32_2, base_x, base_y);

        /* Abort key generation if random number is too small */
        if (bitvec_degree(private_key_int32) < (CURVE_DEGREE / 2)) {
            return false;
        } else {
            /* Clear bits > CURVE_DEGREE in highest word to satisfy constraint 1 <= exp < n. */
            int nbits = bitvec_degree(base_order);
            int i;

            for (i = (nbits - 1); i < (BITVEC_NWORDS * 32); ++i) {
                bitvec_clr_bit(private_key_int32, i);
            }

            /* Multiply base-point with scalar (private-key) */
            gf2point_mul(public_key_int32_1, public_key_int32_2, private_key_int32);

            ints_to_bytes(public_key, public_key_int32_1, 0);
            ints_to_bytes(public_key, public_key_int32_2, BITVEC_NBYTES);

            return true;
        }
    }

    static bool ecdh_shared_secret(Uint8List private_key, Uint8List others_pub, Uint8List output) {
        List<int> private_key_int32 = bytes_to_int(private_key, 0);
        List<int> others_pub_int32_1 = bytes_to_int(others_pub, 0);
        List<int> others_pub_int32_2 = bytes_to_int(others_pub, BITVEC_NBYTES);

        /* Do some basic validation of other party's key */

        if (!gf2point_is_zero(others_pub_int32_1, others_pub_int32_2)
                && gf2point_on_curve(others_pub_int32_1, others_pub_int32_2)) {
            /* Copy other side's key to output */
            int i;
            for (i = 0; i < (BITVEC_NBYTES * 2); ++i) {
                output[i] = others_pub[i];
            }

            /* Clear bits > CURVE_DEGREE in highest word to satisfy constraint 1 <= exp < n. */
            int nbits = bitvec_degree(base_order);

            for (i = (nbits - 1); i < (BITVEC_NWORDS * 32); ++i) {
                bitvec_clr_bit(private_key_int32, i);
            }

            /* Multiply other side's key with own key */
            List<int> output_int32_1 = bytes_to_int(output, 0);
            List<int> output_int32_2 = bytes_to_int(output, BITVEC_NBYTES);

            gf2point_mul(output_int32_1, output_int32_2, private_key_int32);

            ints_to_bytes(output, output_int32_1, 0);
            ints_to_bytes(output, output_int32_2, BITVEC_NBYTES);

            return true;
        } else {
            return false;
        }
    }

    static Uint8List? ecdhGeneratePublic(Uint8List privateEC) {
    final pubKey = Uint8List(ECC_PUB_KEY_SIZE);
    // privateEC is mutated (bits cleared) like the C version
    if (ecdh_generate_keys(pubKey, privateEC)) {
      return pubKey;
    }
    return null;
  }

  static Uint8List? ecdhGenerateShared(Uint8List privateEC, Uint8List remotePublicEC) {
    final sharedKey = Uint8List(ECC_PUB_KEY_SIZE);
    if (ecdh_shared_secret(privateEC, remotePublicEC, sharedKey)) {
      return sharedKey;
    }
    return null;
  }

}
