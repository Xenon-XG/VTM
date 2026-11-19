#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE="$ROOT/VTM/Native/WebRTCVAD"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/check.c" <<'C'
#include "VTMLiveVAD.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    int16_t silence[480] = {0};
    void *a = VTMLiveVADCreate();
    void *b = VTMLiveVADCreate();
    assert(a && b && a != b);
    assert(VTMLiveVADProcess(a, silence, 160) == 0);
    assert(VTMLiveVADProcess(a, silence, 320) == 0);
    assert(VTMLiveVADProcess(b, silence, 480) == 0);
    assert(VTMLiveVADProcess(a, silence, 159) == -1);
    assert(VTMLiveVADProcess(a, NULL, 320) == -1);
    assert(VTMLiveVADProcess(NULL, silence, 320) == -1);
    VTMLiveVADFree(a);
    VTMLiveVADFree(b);
    VTMLiveVADFree(NULL);
    puts("WebRTC VAD bridge compile/link and PCM16 frame checks passed");
    return 0;
}
C

while IFS= read -r -d '' file; do
    driver="${CC:-cc}"
    if [[ "$file" == *.cc ]]; then driver="${CXX:-c++}"; fi
    "$driver" -O2 -DWEBRTC_POSIX=1 -I "$NATIVE" -c "$file" -o "$TMP/$(basename "$file").o"
done < <(find "$NATIVE" "$TMP" -type f \( -name '*.c' -o -name '*.cc' \) -print0)

"${CXX:-c++}" -pthread "$TMP/"*.o -o "$TMP/check"
"$TMP/check"
