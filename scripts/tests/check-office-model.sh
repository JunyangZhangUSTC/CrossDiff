#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
check_build="$project_root/.build-office-model-checks"
mkdir -p "$check_build/module-cache" "$check_build/fixtures"
python3 - "$check_build/fixtures" <<'PY'
from pathlib import Path
import sys, zipfile
out = Path(sys.argv[1])
r = 'http://schemas.openxmlformats.org/package/2006/relationships'
o = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
s = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
c = 'http://schemas.openxmlformats.org/package/2006/content-types'
for filename, names in [('model-left.xlsx', ['Alpha', 'Beta']), ('model-right.xlsx', ['Beta', 'Alpha']), ('model-empty.xlsx', [])]:
    sheets = ''.join(f'<sheet name="{name}" sheetId="{i}" r:id="r{i}"/>' for i, name in enumerate(names, 1))
    relationships = ''.join(f'<Relationship Id="r{i}" Type="{o}/worksheet" Target="worksheets/sheet{i}.xml"/>' for i in range(1, len(names)+1))
    parts = {'[Content_Types].xml': f'<Types xmlns="{c}"><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/></Types>',
             '_rels/.rels': f'<Relationships xmlns="{r}"><Relationship Id="main" Type="{o}/officeDocument" Target="xl/workbook.xml"/></Relationships>',
             'xl/workbook.xml': f'<workbook xmlns="{s}" xmlns:r="{o}"><sheets>{sheets}</sheets></workbook>',
             'xl/_rels/workbook.xml.rels': f'<Relationships xmlns="{r}">{relationships}</Relationships>'}
    for i, name in enumerate(names, 1):
        parts[f'xl/worksheets/sheet{i}.xml'] = f'<worksheet xmlns="{s}"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>{name}</t></is></c><c r="B1"><v>42</v></c></row></sheetData></worksheet>'
    with zipfile.ZipFile(out / filename, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path, contents in parts.items(): archive.writestr(path, contents)
PY
swiftc -swift-version 5 -module-cache-path "$check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  Sources/CrossDiffCore/*.swift -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc -parse-as-library -swift-version 5 -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  Sources/CrossDiff/OfficeComparisonModel.swift scripts/tests/OfficeModelChecks.swift -o "$check_build/office-model-checks"
if [[ "${1:-}" == "--build-only" ]]; then
  echo "Built Office model checks."
  exit 0
fi
"$check_build/office-model-checks" "$check_build/fixtures"
