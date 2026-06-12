import os
import re

PARAM_DIR = r"c:\VsCode\AzureIaCSamples\AzurePolicy\CustomPolicies\PolicyConversion\PoliciesBicepParam"

updated = 0
for filename in os.listdir(PARAM_DIR):
    if not filename.endswith(".bicepparam"):
        continue
    slug = os.path.splitext(filename)[0]
    filepath = os.path.join(PARAM_DIR, filename)
    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()
    new_content = re.sub(
        r"^param policyDefinitionName = '.*'",
        f"param policyDefinitionName = '{slug}'",
        content,
        count=1,
        flags=re.MULTILINE,
    )
    if new_content != content:
        with open(filepath, "w", encoding="utf-8") as f:
            f.write(new_content)
        updated += 1

print(f"Updated {updated} files.")
