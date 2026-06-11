import json
import os
import re

OUTPUT_DIR = r"c:\VsCode\AzureIaCSamples\AzurePolicy\CustomPolicies\PolicyConversion\PoliciesBicepParam"

TAG_NAME_PARAM = {
    "type": "String",
    "metadata": {
        "description": "Name of the Tag, such as environment",
        "displayName": "Tag Name"
    }
}

TAG_VALUE_PARAM = {
    "type": "String",
    "metadata": {
        "description": "Value of the Tag, such as Prod",
        "displayName": "Tag Value"
    }
}

TAG_CONDITION = {
    "field": "[concat('tags[', parameters('tagName'), ']')]",
    "equals": "[parameters('tagValue')]"
}


def extract_triple_quoted(content, param_name):
    match = re.search(rf"param {param_name} = '''\n(.*?)\n'''", content, re.DOTALL)
    return match.group(1) if match else None


def replace_triple_quoted(content, param_name, new_value):
    return re.sub(
        rf"(param {param_name} = '''\n).*?(\n''')",
        rf"\g<1>{new_value}\g<2>",
        content,
        flags=re.DOTALL,
    )


updated = 0
errors = []

for filename in sorted(os.listdir(OUTPUT_DIR)):
    if not filename.endswith(".bicepparam"):
        continue

    filepath = os.path.join(OUTPUT_DIR, filename)
    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()

    try:
        # --- policyParameters: append tagName and tagValue ---
        params_str = extract_triple_quoted(content, "policyParameters")
        if params_str is None:
            raise ValueError("policyParameters triple-quoted block not found")
        params = json.loads(params_str)
        params["tagName"] = TAG_NAME_PARAM
        params["tagValue"] = TAG_VALUE_PARAM
        content = replace_triple_quoted(content, "policyParameters", json.dumps(params, indent=2, ensure_ascii=False))

        # --- policyRule: insert tag condition after the "field":"type" entry ---
        rule_str = extract_triple_quoted(content, "policyRule")
        if rule_str is None:
            raise ValueError("policyRule triple-quoted block not found")
        rule = json.loads(rule_str)

        all_of = rule.get("if", {}).get("allOf", [])
        type_idx = next((i for i, c in enumerate(all_of) if c.get("field") == "type"), None)

        if type_idx is None:
            raise ValueError("Could not find 'field':'type' condition in policyRule.if.allOf")

        # Only insert if tag condition not already present
        already_has_tag = any(
            "tagName" in str(c.get("field", "")) for c in all_of
        )
        if not already_has_tag:
            all_of.insert(type_idx + 1, TAG_CONDITION)

        content = replace_triple_quoted(content, "policyRule", json.dumps(rule, indent=2, ensure_ascii=False))

        with open(filepath, "w", encoding="utf-8") as f:
            f.write(content)

        updated += 1

    except Exception as e:
        errors.append(f"{filename}: {e}")

print(f"Updated {updated} files.")
if errors:
    print(f"\nErrors ({len(errors)}):")
    for e in errors:
        print(f"  {e}")
