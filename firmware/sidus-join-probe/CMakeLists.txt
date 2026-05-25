# SPDX-License-Identifier: Apache-2.0

cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(sidus_join_probe)

set(AMARAN_PROBE_UUID_STRING "400M5-C0DE0100fp" CACHE STRING "16-byte fixture-like provisioning UUID")
set(AMARAN_PROBE_MANUFACTURER_DATA_HEX "" CACHE STRING "Optional manufacturer data payload hex")
set(AMARAN_PROBE_LOCAL_IDENTITY_DIR "" CACHE PATH "Optional private include directory for local identity overrides")
option(AMARAN_PROBE_REAL_GATT_LAYOUT "Use the real 60x-like pre-provisioning GATT layout" OFF)
option(AMARAN_PROBE_PREPROVISION_PROXY "Register the Mesh Proxy GATT service before provisioning completes" ON)

target_sources(app PRIVATE src/main.c)
if(AMARAN_PROBE_LOCAL_IDENTITY_DIR)
  target_include_directories(app PRIVATE "${AMARAN_PROBE_LOCAL_IDENTITY_DIR}")
else()
  target_compile_definitions(app PRIVATE
    AMARAN_PROBE_UUID_STRING="${AMARAN_PROBE_UUID_STRING}"
    AMARAN_PROBE_MANUFACTURER_DATA_HEX="${AMARAN_PROBE_MANUFACTURER_DATA_HEX}"
  )
endif()

if(AMARAN_PROBE_REAL_GATT_LAYOUT)
  target_compile_definitions(app PRIVATE AMARAN_PROBE_REAL_GATT_LAYOUT=1)
  target_compile_definitions(zephyr PRIVATE AMARAN_PROBE_REAL_GATT_LAYOUT=1)
endif()

if(AMARAN_PROBE_PREPROVISION_PROXY)
  target_compile_definitions(zephyr PRIVATE AMARAN_PROBE_PREPROVISION_PROXY=1)
endif()
