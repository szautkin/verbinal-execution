#!/usr/bin/env bash
# Verify the bundled science stack actually imports in the runtime image -- this
# is what catches a missing runtime shared library (e.g. a source-built fitsio
# linking libcfitsio that isn't installed in the runtime stage).
#
#   docker run --rm --entrypoint bash <image> /src/test/imports.sh   # with /src mounted
# or simply run it inside the image where it ships.

set -u
PKGS="numpy scipy pandas matplotlib astropy astroquery photutils specutils reproject regions fitsio h5py sklearn skimage yaml requests tqdm IPython canfar"
PASS=0; FAIL=0
for p in $PKGS; do
    if python3 -c "import $p" 2>/tmp/imperr; then
        printf '  \033[32mPASS\033[0m import %s\n' "$p"; PASS=$((PASS+1))
    else
        printf '  \033[31mFAIL\033[0m import %s -- %s\n' "$p" "$(tail -1 /tmp/imperr)"; FAIL=$((FAIL+1))
    fi
done
# A representative end-to-end exercise that touches compiled paths.
python3 - <<'PY' && echo "  smoke: numpy/scipy/astropy compute OK" || { echo "  smoke FAILED"; FAIL=$((FAIL+1)); }
import numpy as np, scipy.linalg as sla
from astropy.io import fits
a = np.random.RandomState(0).rand(50, 50)
assert sla.det(a @ a.T) >= 0
h = fits.PrimaryHDU(a); assert h.data.shape == (50, 50)
PY
echo
echo "==== $PASS imports passed, $FAIL failed ===="
[ "$FAIL" -eq 0 ]
