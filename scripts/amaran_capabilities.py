def normalized_mac(value):
    return "".join(ch for ch in str(value or "") if ch in "0123456789abcdefABCDEF").upper()


def mac_suffix(value):
    return normalized_mac(value)[-6:]


def fixture_label(fixture):
    if not isinstance(fixture, dict):
        return "selected fixture"
    if fixture.get("friendly_name"):
        return str(fixture["friendly_name"])
    if fixture.get("name"):
        return str(fixture["name"])
    suffix = mac_suffix(fixture.get("mac_address"))
    code = fixture.get("code")
    if code and suffix:
        return f"{code}-{suffix}"
    return suffix or f"fixture-{fixture.get('node_address', 'unknown')}"


def selector_values(fixture):
    values = []
    if not isinstance(fixture, dict):
        return values
    address = fixture.get("node_address")
    if isinstance(address, int):
        values.extend([str(address), hex(address)])
    for key in ("friendly_name", "name"):
        value = fixture.get(key)
        if isinstance(value, str) and value:
            values.append(value)
    label = fixture_label(fixture)
    if label:
        values.append(label)
    return values


def selected_fixture(fixtures, selector):
    candidates = [fixture for fixture in fixtures or [] if isinstance(fixture, dict)]
    if selector:
        selector_text = str(selector)
        matches = [
            fixture
            for fixture in candidates
            if any(value == selector_text for value in selector_values(fixture))
        ]
        return matches[0] if len(matches) == 1 else None
    return candidates[0] if len(candidates) == 1 else None


def fixture_capabilities(fixture):
    capabilities = {
        "cct_min": 2000,
        "cct_max": 10000,
        "gm_supported": True,
    }
    if isinstance(fixture, dict):
        code = str(fixture.get("code") or "").upper()
        source_name = str(fixture.get("name") or "").upper()
        if code == "400M5" or source_name.startswith("400M5-"):
            capabilities.update({
                "cct_min": 2700,
                "cct_max": 6500,
                "gm_supported": False,
            })
        explicit = fixture.get("capabilities")
        if isinstance(explicit, dict):
            for key in ("cct_min", "cct_max"):
                value = explicit.get(key)
                if isinstance(value, (int, float)):
                    capabilities[key] = int(value)
            if "gm_supported" in explicit:
                capabilities["gm_supported"] = bool(explicit["gm_supported"])
    if capabilities["cct_min"] > capabilities["cct_max"]:
        capabilities["cct_min"], capabilities["cct_max"] = capabilities["cct_max"], capabilities["cct_min"]
    return capabilities


def fixture_gm_supported(fixture):
    return fixture_capabilities(fixture)["gm_supported"]


def normalize_cct_kelvin(value):
    if not isinstance(value, (int, float)):
        return value
    if value < 1000:
        return value * 10
    return value


def clamp_cct_for_fixture(value, fixture):
    cct = normalize_cct_kelvin(value)
    if not isinstance(cct, (int, float)):
        return cct
    capabilities = fixture_capabilities(fixture)
    return max(capabilities["cct_min"], min(capabilities["cct_max"], int(cct)))
