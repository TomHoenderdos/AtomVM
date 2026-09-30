#
# SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
#
# Build settings for the badge that are not sdkconfig options. No sources:
# this component exists to pull libsodium in (idf_component.yml) and to
# compile the TLS crypto for speed.

idf_component_register(REQUIRES mbedtls)

# The global -Os is slowest exactly where the TLS handshake spends its time.
# ECC verification has to beat ngrok's ~1s edge deadline, so the crypto
# objects alone are compiled for speed.
foreach(crypto_target mbedcrypto mbedtls mbedx509)
    if(NOT TARGET ${crypto_target})
        message(FATAL_ERROR "badge: ${crypto_target} is not defined yet")
    endif()
    target_compile_options(${crypto_target} PRIVATE -O2)
endforeach()
