import os
import re

PARAM_DIR = r"c:\VsCode\AzureIaCSamples\AzurePolicy\CustomPolicies\PolicyConversion\PoliciesBicepParam"


def display_name_to_slug(display_name: str) -> str:
    # Remove parenthetical resource-type segments e.g. (microsoft.aad/domainservices)
    slug = re.sub(r"\([^)]*\)", "", display_name)
    # Remove trailing "to Log Analytics" / "to Storage Account" / "to Event Hub" destination suffixes
    slug = re.sub(r"\s+to\s+\S.*$", "", slug, flags=re.IGNORECASE)
    # Lowercase
    slug = slug.lower()
    # Replace any non-alphanumeric run with a single hyphen
    slug = re.sub(r"[^a-z0-9]+", "-", slug)
    # Strip leading/trailing hyphens
    slug = slug.strip("-")
    return slug


def extract_param(content: str, param_name: str) -> str:
    """Return the single-line string value of a param X = '...' line."""
    match = re.search(rf"^param {param_name} = '(.*)'", content, re.MULTILINE)
    return match.group(1) if match else ""


files = [f for f in os.listdir(PARAM_DIR) if f.endswith(".bicepparam")]

# Build slug → list of files mapping to detect collisions before renaming
slug_map: dict[str, list[str]] = {}
for filename in files:
    filepath = os.path.join(PARAM_DIR, filename)
    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()
    display_name = extract_param(content, "policydisplayName")
    slug = display_name_to_slug(display_name) if display_name else os.path.splitext(filename)[0]
    slug_map.setdefault(slug, []).append(filename)

renamed = 0
skipped = 0
errors = []

for slug, filenames in sorted(slug_map.items()):
    for i, filename in enumerate(filenames):
        # Append index suffix only when there's a collision
        new_name = f"{slug}-{i + 1}.bicepparam" if len(filenames) > 1 else f"{slug}.bicepparam"
        old_path = os.path.join(PARAM_DIR, filename)
        new_path = os.path.join(PARAM_DIR, new_name)

        if filename == new_name:
            skipped += 1
            continue
        if os.path.exists(new_path):
            errors.append(f"Target already exists, skipping: {new_name}")
            continue

        try:
            os.rename(old_path, new_path)
            renamed += 1
        except OSError as e:
            errors.append(f"{filename}: {e}")

print(f"Renamed {renamed} files, {skipped} already correct.")
if errors:
    print(f"\nCollisions / errors ({len(errors)}):")
    for e in errors:
        print(f"  {e}")
