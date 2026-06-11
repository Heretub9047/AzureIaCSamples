import json
import os

JSON_DIR = r"c:\VsCode\AzureIaCSamples\AzurePolicy\CustomPolicies\PolicyConversion\PoliciesJSON"
OUTPUT_DIR = r"c:\VsCode\AzureIaCSamples\AzurePolicy\CustomPolicies\PolicyConversion\PoliciesBicepParam"

os.makedirs(OUTPUT_DIR, exist_ok=True)

converted = 0
errors = []

for filename in os.listdir(JSON_DIR):
    if not filename.endswith(".json"):
        continue

    filepath = os.path.join(JSON_DIR, filename)
    with open(filepath, "r", encoding="utf-8") as f:
        try:
            policy = json.load(f)
        except json.JSONDecodeError as e:
            errors.append(f"{filename}: {e}")
            continue

    # Escape single quotes for bicep single-quoted string params
    name         = (policy.get("name", "") or "").replace("'", "''")
    display_name = (policy.get("displayName", "") or "").replace("'", "''")
    description  = (policy.get("description", "") or "").replace("'", "''")

    metadata_json   = json.dumps(policy.get("metadata", {}),   indent=2, ensure_ascii=False)
    parameters_json = json.dumps(policy.get("parameters", {}), indent=2, ensure_ascii=False)
    policy_rule_json = json.dumps(policy.get("policyRule", {}), indent=2, ensure_ascii=False)

    content = f"""using '../main.bicep'

param policyDefinitionName = '{name}'

param policydisplayName = '{display_name}'

param description = '{description}'

param metadata = '''
{metadata_json}
'''

param policyParameters = '''
{parameters_json}
'''

param policyRule = '''
{policy_rule_json}
'''
"""

    out_name = os.path.splitext(filename)[0] + ".bicepparam"
    out_path = os.path.join(OUTPUT_DIR, out_name)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(content)

    converted += 1

print(f"Converted {converted} files.")
if errors:
    print(f"\nErrors ({len(errors)}):")
    for e in errors:
        print(f"  {e}")
