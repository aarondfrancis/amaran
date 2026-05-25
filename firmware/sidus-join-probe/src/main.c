/*
 * Minimal Sidus join probe for nRF52840 DK.
 *
 * This is intentionally a fake provisionee. It exposes enough Bluetooth Mesh
 * identity to test whether Sidus Link Pro will provision it into an existing
 * studio mesh. It must not print or persist captured keys outside the mesh
 * stack without an explicit key-handling path.
 */

#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/addr.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/mesh.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/device.h>
#include <zephyr/drivers/hwinfo.h>
#include <zephyr/kernel.h>
#include <zephyr/linker/section_tags.h>
#include <zephyr/settings/settings.h>
#include <zephyr/sys/byteorder.h>
#include <zephyr/sys/printk.h>
#include <zephyr/toolchain.h>

#define AMARAN_COMPANY_ID 0x0211
#define AMARAN_PRODUCT_ID 0x0000
#define AMARAN_VERSION_ID 0x3333
#define AMARAN_VENDOR_MODEL_ID 0x0000
#define AMARAN_VENDOR_OPCODE BT_MESH_MODEL_OP_3(0x26, AMARAN_COMPANY_ID)

#if __has_include("amaran_probe_local_identity.h")
#include "amaran_probe_local_identity.h"
#endif

#ifndef AMARAN_PROBE_UUID_STRING
#define AMARAN_PROBE_UUID_STRING "400M5-C0DE0100fp"
#endif

#ifndef AMARAN_PROBE_MANUFACTURER_DATA_HEX
#define AMARAN_PROBE_MANUFACTURER_DATA_HEX ""
#endif

#define AMARAN_CAPTURE_MAGIC 0x414d4341u
#define AMARAN_CAPTURE_CLEAR_MAGIC 0x414d4343u
#define AMARAN_CAPTURE_VERSION 2u
#define AMARAN_CAPTURE_PROVISIONING_SEEN 0x00000001u
#define AMARAN_CAPTURE_APPKEY_SEEN 0x00000002u
#define AMARAN_CAPTURE_NETKEY_IMPORT_SEEN 0x00000004u
#define AMARAN_CAPTURE_APPKEY_IMPORT_SEEN 0x00000008u
#define AMARAN_CAPTURE_DEVICEKEY_IMPORT_SEEN 0x00000010u
#define AMARAN_CAPTURE_KEY_TYPE_NET 3u
#define AMARAN_CAPTURE_KEY_TYPE_APP 4u
#define AMARAN_CAPTURE_KEY_TYPE_DEV 5u
#define AMARAN_CAPTURE_SETTINGS_KEY "amaran/capture"
#define AMARAN_CAPTURE_DEBUG_MASK_OFFSET 0u
#define AMARAN_CAPTURE_DEBUG_CAPS_ALGORITHM_OFFSET 5u
#define AMARAN_CAPTURE_DEBUG_EVENT_OFFSET 4u
#define AMARAN_CAPTURE_DEBUG_VALUE_OFFSET 6u
#define AMARAN_CAPTURE_DEBUG_COUNT_OFFSET 8u
#define AMARAN_CAPTURE_DEBUG_CAPS_PUBLIC_KEY_OFFSET 12u
#define AMARAN_CAPTURE_DEBUG_CAPS_OOB_TYPE_OFFSET 13u
#define AMARAN_CAPTURE_DEBUG_START_ALGORITHM_OFFSET 14u
#define AMARAN_CAPTURE_DEBUG_START_PUBLIC_KEY_OFFSET 15u
#define AMARAN_CAPTURE_DEBUG_START_AUTH_METHOD_OFFSET 16u
#define AMARAN_CAPTURE_DEBUG_START_AUTH_ACTION_OFFSET 17u
#define AMARAN_CAPTURE_DEBUG_START_AUTH_SIZE_OFFSET 18u
#define AMARAN_CAPTURE_DEBUG_EVENT_RING_COUNT 64u

struct amaran_capture_debug_event {
	uint8_t event_code;
	uint8_t reserved;
	uint16_t value;
	uint32_t count;
	uint32_t uptime_ms;
	uint32_t fingerprint;
};

struct amaran_capture_state {
	uint32_t magic;
	uint16_t version;
	uint16_t length;
	uint32_t seen_mask;
	uint32_t record_count;
	uint8_t net_key[16];
	uint8_t device_key[16];
	uint8_t app_key[16];
	uint16_t net_idx;
	uint16_t app_net_idx;
	uint16_t app_idx;
	uint16_t provisioned_address;
	uint32_t iv_index;
	uint8_t key_refresh_flags;
	uint8_t reserved[19];
	uint32_t debug_event_count;
	uint8_t debug_event_pos;
	uint8_t debug_event_capacity;
	uint16_t debug_event_reserved;
	struct amaran_capture_debug_event debug_events[AMARAN_CAPTURE_DEBUG_EVENT_RING_COUNT];
};

static uint8_t dev_uuid[16];
struct amaran_capture_state __noinit_named(amaran_capture_state)
	__aligned(4) amaran_capture_state;

struct amaran_gatt_read_value {
	const uint8_t *data;
	uint16_t len;
};

static const uint8_t gatt_zero1[] = { 0x00 };
static const uint8_t gatt_zero2[] = { 0x00, 0x00 };
static const uint8_t gatt_pnp_id[] = {
	0x02, 0x8a, 0x24, 0x66, 0x82, 0x01, 0x00,
};
static const uint8_t gatt_firmware_revision[] = {
	0x00, 0x00, 0x31, 0x18, 0x33, 0x33, 0x34, 0x00, 0x00,
};

static const struct amaran_gatt_read_value gatt_zero1_value = {
	.data = gatt_zero1,
	.len = sizeof(gatt_zero1),
};
static const struct amaran_gatt_read_value gatt_zero2_value = {
	.data = gatt_zero2,
	.len = sizeof(gatt_zero2),
};
static const struct amaran_gatt_read_value gatt_pnp_id_value = {
	.data = gatt_pnp_id,
	.len = sizeof(gatt_pnp_id),
};
static const struct amaran_gatt_read_value gatt_firmware_revision_value = {
	.data = gatt_firmware_revision,
	.len = sizeof(gatt_firmware_revision),
};

static ssize_t amaran_gatt_read(struct bt_conn *conn,
				const struct bt_gatt_attr *attr, void *buf,
				uint16_t len, uint16_t offset)
{
	const struct amaran_gatt_read_value *value = attr->user_data;
	char uuid[BT_UUID_STR_LEN];

	bt_uuid_to_str(attr->uuid, uuid, sizeof(uuid));
	printk("mirror gatt read uuid=%s value_len=%u offset=%u\n",
	       uuid, value->len, offset);
	return bt_gatt_attr_read(conn, attr, buf, len, offset, value->data,
				 value->len);
}

static ssize_t amaran_gatt_write(struct bt_conn *conn,
				 const struct bt_gatt_attr *attr,
				 const void *buf, uint16_t len, uint16_t offset,
				 uint8_t flags)
{
	char uuid[BT_UUID_STR_LEN];

	ARG_UNUSED(conn);
	ARG_UNUSED(buf);

	bt_uuid_to_str(attr->uuid, uuid, sizeof(uuid));
	printk("mirror gatt write uuid=%s len=%u offset=%u flags=0x%02x\n",
	       uuid, len, offset, flags);
	return len;
}

static void amaran_gatt_ccc_changed(const struct bt_gatt_attr *attr,
				    uint16_t value)
{
	char uuid[BT_UUID_STR_LEN];

	bt_uuid_to_str(attr->uuid, uuid, sizeof(uuid));
	printk("mirror gatt ccc uuid=%s value=0x%04x\n",
	       uuid, value);
}

#define AMARAN_UUID_1912 \
	BT_UUID_DECLARE_128(BT_UUID_128_ENCODE(0x00010203, 0x0405, 0x0607, 0x0809, 0x0a0b0c0d1912))
#define AMARAN_UUID_2B12 \
	BT_UUID_DECLARE_128(BT_UUID_128_ENCODE(0x00010203, 0x0405, 0x0607, 0x0809, 0x0a0b0c0d2b12))
#define AMARAN_UUID_7FDE_128 \
	BT_UUID_DECLARE_128(BT_UUID_128_ENCODE(0x00010203, 0x0405, 0x0607, 0x0809, 0x0a0b0c0d7fde))
#define AMARAN_UUID_7FDF_128 \
	BT_UUID_DECLARE_128(BT_UUID_128_ENCODE(0x00010203, 0x0405, 0x0607, 0x0809, 0x0a0b0c0d7fdf))
#define AMARAN_UUID_7FD3 BT_UUID_DECLARE_16(0x7fd3)
#define AMARAN_UUID_7FCB BT_UUID_DECLARE_16(0x7fcb)
#define AMARAN_UUID_7FDD BT_UUID_DECLARE_16(0x7fdd)
#define AMARAN_UUID_FF01 BT_UUID_DECLARE_16(0xff01)
#define AMARAN_UUID_FF02 BT_UUID_DECLARE_16(0xff02)

#if defined(AMARAN_PROBE_REAL_GATT_LAYOUT)
BT_GATT_SERVICE_DEFINE(amaran_device_info_svc,
	BT_GATT_PRIMARY_SERVICE(BT_UUID_DIS),
	BT_GATT_CHARACTERISTIC(BT_UUID_DIS_PNP_ID, BT_GATT_CHRC_READ,
			       BT_GATT_PERM_READ, amaran_gatt_read, NULL,
			       (void *)&gatt_pnp_id_value),
	BT_GATT_CHARACTERISTIC(BT_UUID_DIS_FIRMWARE_REVISION,
			       BT_GATT_CHRC_READ, BT_GATT_PERM_READ,
			       amaran_gatt_read, NULL,
			       (void *)&gatt_firmware_revision_value),
);
#endif

BT_GATT_SERVICE_DEFINE(amaran_identity_svc,
	BT_GATT_PRIMARY_SERVICE(AMARAN_UUID_1912),
	BT_GATT_CHARACTERISTIC(AMARAN_UUID_2B12,
			       BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE_WITHOUT_RESP,
			       BT_GATT_PERM_READ | BT_GATT_PERM_WRITE,
			       amaran_gatt_read, amaran_gatt_write,
			       (void *)&gatt_zero1_value),
);

#if !defined(AMARAN_PROBE_REAL_GATT_LAYOUT)
BT_GATT_SERVICE_DEFINE(amaran_control_svc,
	BT_GATT_PRIMARY_SERVICE(AMARAN_UUID_7FDE_128),
	BT_GATT_CHARACTERISTIC(AMARAN_UUID_7FDF_128,
			       BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE_WITHOUT_RESP |
				       BT_GATT_CHRC_NOTIFY | BT_GATT_CHRC_INDICATE,
			       BT_GATT_PERM_READ | BT_GATT_PERM_WRITE,
			       amaran_gatt_read, amaran_gatt_write,
			       (void *)&gatt_zero1_value),
	BT_GATT_CCC(amaran_gatt_ccc_changed,
		    BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
);

BT_GATT_SERVICE_DEFINE(amaran_device_info_svc,
	BT_GATT_PRIMARY_SERVICE(BT_UUID_DIS),
	BT_GATT_CHARACTERISTIC(BT_UUID_DIS_PNP_ID, BT_GATT_CHRC_READ,
			       BT_GATT_PERM_READ, amaran_gatt_read, NULL,
			       (void *)&gatt_pnp_id_value),
	BT_GATT_CHARACTERISTIC(BT_UUID_DIS_FIRMWARE_REVISION,
			       BT_GATT_CHRC_READ, BT_GATT_PERM_READ,
			       amaran_gatt_read, NULL,
			       (void *)&gatt_firmware_revision_value),
);

BT_GATT_SERVICE_DEFINE(amaran_7fd3_svc,
	BT_GATT_PRIMARY_SERVICE(AMARAN_UUID_7FD3),
	BT_GATT_CHARACTERISTIC(AMARAN_UUID_7FCB,
			       BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE_WITHOUT_RESP |
				       BT_GATT_CHRC_NOTIFY,
			       BT_GATT_PERM_READ | BT_GATT_PERM_WRITE,
			       amaran_gatt_read, amaran_gatt_write,
			       (void *)&gatt_zero2_value),
	BT_GATT_CCC(amaran_gatt_ccc_changed,
		    BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
);

BT_GATT_SERVICE_DEFINE(amaran_7fdd_svc,
	BT_GATT_PRIMARY_SERVICE(AMARAN_UUID_7FDD),
	BT_GATT_CHARACTERISTIC(BT_UUID_MESH_PROXY_DATA_OUT, BT_GATT_CHRC_NOTIFY,
			       BT_GATT_PERM_NONE, NULL, NULL, NULL),
	BT_GATT_CCC(amaran_gatt_ccc_changed,
		    BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
	BT_GATT_CHARACTERISTIC(BT_UUID_MESH_PROXY_DATA_IN,
			       BT_GATT_CHRC_WRITE_WITHOUT_RESP,
			       BT_GATT_PERM_WRITE, NULL, amaran_gatt_write,
			       NULL),
);

BT_GATT_SERVICE_DEFINE(amaran_ff01_svc,
	BT_GATT_PRIMARY_SERVICE(AMARAN_UUID_FF01),
	BT_GATT_CHARACTERISTIC(AMARAN_UUID_FF02,
			       BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE_WITHOUT_RESP |
				       BT_GATT_CHRC_NOTIFY,
			       BT_GATT_PERM_READ | BT_GATT_PERM_WRITE,
			       amaran_gatt_read, amaran_gatt_write,
			       (void *)&gatt_zero2_value),
	BT_GATT_CCC(amaran_gatt_ccc_changed,
		    BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
);
#endif

static int amaran_probe_hex_nibble(char value)
{
	if (value >= '0' && value <= '9') {
		return value - '0';
	}
	if (value >= 'a' && value <= 'f') {
		return value - 'a' + 10;
	}
	if (value >= 'A' && value <= 'F') {
		return value - 'A' + 10;
	}
	return -1;
}

static size_t amaran_probe_parse_hex_payload(const char *hex, uint8_t *out,
					     size_t out_len)
{
	size_t count = 0;
	int high = -1;

	for (size_t i = 0; hex[i] != '\0'; i++) {
		int nibble = amaran_probe_hex_nibble(hex[i]);

		if (nibble < 0) {
			continue;
		}
		if (high < 0) {
			high = nibble;
			continue;
		}
		if (count >= out_len) {
			return 0;
		}
		out[count++] = (uint8_t)((high << 4) | nibble);
		high = -1;
	}

	return high < 0 ? count : 0;
}

static void amaran_probe_set_identity_from_manufacturer_data(void)
{
	uint8_t manufacturer_data[31];
	size_t len = amaran_probe_parse_hex_payload(
		AMARAN_PROBE_MANUFACTURER_DATA_HEX, manufacturer_data,
		sizeof(manufacturer_data));

	if (len < 9 || sys_get_le16(manufacturer_data) != AMARAN_COMPANY_ID) {
		return;
	}

	bt_addr_le_t addr = {
		.type = BT_ADDR_LE_PUBLIC,
	};

	/* Manufacturer bytes 3..8 are the fixture-like public BLE identity. */
	for (size_t i = 0; i < sizeof(addr.a.val); i++) {
		addr.a.val[i] = manufacturer_data[8 - i];
	}

	int id = bt_id_create(&addr, NULL);
	printk("identity from manufacturer suffix %02x%02x%02x id=%d\n",
	       manufacturer_data[6], manufacturer_data[7],
	       manufacturer_data[8], id);
}

static int amaran_capture_settings_set(const char *name, size_t len,
				       settings_read_cb read_cb, void *cb_arg)
{
	ssize_t bytes_read;

	if (strcmp(name, "capture") != 0) {
		return -ENOENT;
	}
	if (len != sizeof(amaran_capture_state)) {
		return -EINVAL;
	}

	bytes_read = read_cb(cb_arg, &amaran_capture_state,
			     sizeof(amaran_capture_state));
	if (bytes_read != sizeof(amaran_capture_state)) {
		memset(&amaran_capture_state, 0, sizeof(amaran_capture_state));
		return -EINVAL;
	}
	if (amaran_capture_state.magic != AMARAN_CAPTURE_MAGIC ||
	    amaran_capture_state.version != AMARAN_CAPTURE_VERSION ||
	    amaran_capture_state.length != sizeof(amaran_capture_state)) {
		memset(&amaran_capture_state, 0, sizeof(amaran_capture_state));
		return -EINVAL;
	}

	return 0;
}

static struct settings_handler amaran_capture_settings = {
	.name = "amaran",
	.h_set = amaran_capture_settings_set,
};

static void amaran_capture_init(void)
{
	if (amaran_capture_state.magic == AMARAN_CAPTURE_MAGIC &&
	    amaran_capture_state.version == AMARAN_CAPTURE_VERSION &&
	    amaran_capture_state.length == sizeof(amaran_capture_state)) {
		return;
	}

	memset(&amaran_capture_state, 0, sizeof(amaran_capture_state));
	amaran_capture_state.magic = AMARAN_CAPTURE_MAGIC;
	amaran_capture_state.version = AMARAN_CAPTURE_VERSION;
	amaran_capture_state.length = sizeof(amaran_capture_state);
}

static void amaran_capture_save(void)
{
	if (IS_ENABLED(CONFIG_SETTINGS)) {
		(void)settings_save_one(AMARAN_CAPTURE_SETTINGS_KEY,
					&amaran_capture_state,
					sizeof(amaran_capture_state));
	}
}

void amaran_capture_record_provisioning(const uint8_t *net_key,
					const uint8_t *device_key,
					uint16_t net_idx,
					uint8_t key_refresh_flags,
					uint32_t iv_index,
					uint16_t provisioned_address)
{
	amaran_capture_init();
	memcpy(amaran_capture_state.net_key, net_key, 16);
	memcpy(amaran_capture_state.device_key, device_key, 16);
	amaran_capture_state.net_idx = net_idx;
	amaran_capture_state.key_refresh_flags = key_refresh_flags;
	amaran_capture_state.iv_index = iv_index;
	amaran_capture_state.provisioned_address = provisioned_address;
	amaran_capture_state.seen_mask |= AMARAN_CAPTURE_PROVISIONING_SEEN;
	amaran_capture_state.record_count++;
	printk("capture provisioning net_idx=0x%03x addr=0x%04x\n",
	       net_idx, provisioned_address);
	amaran_capture_save();
}

void amaran_capture_record_appkey(const uint8_t *app_key,
				  uint16_t net_idx,
				  uint16_t app_idx)
{
	amaran_capture_init();
	memcpy(amaran_capture_state.app_key, app_key, 16);
	amaran_capture_state.app_net_idx = net_idx;
	amaran_capture_state.app_idx = app_idx;
	amaran_capture_state.seen_mask |= AMARAN_CAPTURE_APPKEY_SEEN;
	amaran_capture_state.record_count++;
	printk("capture appkey net_idx=0x%03x app_idx=0x%03x\n",
	       net_idx, app_idx);
	amaran_capture_save();
}

void amaran_capture_record_key_import(unsigned int key_type, const uint8_t *key)
{
	uint32_t seen_bit;
	uint8_t *capture_key;

	switch (key_type) {
	case AMARAN_CAPTURE_KEY_TYPE_NET:
		seen_bit = AMARAN_CAPTURE_NETKEY_IMPORT_SEEN;
		capture_key = amaran_capture_state.net_key;
		break;
	case AMARAN_CAPTURE_KEY_TYPE_APP:
		seen_bit = AMARAN_CAPTURE_APPKEY_IMPORT_SEEN;
		capture_key = amaran_capture_state.app_key;
		break;
	case AMARAN_CAPTURE_KEY_TYPE_DEV:
		seen_bit = AMARAN_CAPTURE_DEVICEKEY_IMPORT_SEEN;
		capture_key = amaran_capture_state.device_key;
		break;
	default:
		return;
	}

	amaran_capture_init();
	memcpy(capture_key, key, 16);
	amaran_capture_state.seen_mask |= seen_bit;
	amaran_capture_state.record_count++;
	printk("capture key import type=%u\n", key_type);
	amaran_capture_save();
}

static uint32_t amaran_capture_fingerprint(const uint8_t *data, size_t len)
{
	uint32_t hash = 2166136261u;

	for (size_t index = 0; index < len; index++) {
		hash ^= data[index];
		hash *= 16777619u;
	}

	return hash;
}

static void amaran_capture_record_debug_inner(uint32_t event_mask,
					      uint8_t event_code,
					      uint16_t value,
					      uint32_t fingerprint)
{
	uint32_t debug_mask;
	uint32_t debug_count;
	struct amaran_capture_debug_event *event;
	uint8_t event_pos;

	amaran_capture_init();
	debug_mask = sys_get_le32(&amaran_capture_state.reserved[AMARAN_CAPTURE_DEBUG_MASK_OFFSET]);
	sys_put_le32(debug_mask | event_mask,
		     &amaran_capture_state.reserved[AMARAN_CAPTURE_DEBUG_MASK_OFFSET]);
	amaran_capture_state.reserved[AMARAN_CAPTURE_DEBUG_EVENT_OFFSET] = event_code;
	sys_put_le16(value,
		     &amaran_capture_state.reserved[AMARAN_CAPTURE_DEBUG_VALUE_OFFSET]);
	debug_count = sys_get_le32(&amaran_capture_state.reserved[AMARAN_CAPTURE_DEBUG_COUNT_OFFSET]);
	debug_count++;
	sys_put_le32(debug_count,
		     &amaran_capture_state.reserved[AMARAN_CAPTURE_DEBUG_COUNT_OFFSET]);
	amaran_capture_state.debug_event_count = debug_count;
	amaran_capture_state.debug_event_capacity = AMARAN_CAPTURE_DEBUG_EVENT_RING_COUNT;
	event_pos = amaran_capture_state.debug_event_pos % AMARAN_CAPTURE_DEBUG_EVENT_RING_COUNT;
	event = &amaran_capture_state.debug_events[event_pos];
	event->event_code = event_code;
	event->reserved = 0;
	event->value = value;
	event->count = debug_count;
	event->uptime_ms = k_uptime_get_32();
	event->fingerprint = fingerprint;
	amaran_capture_state.debug_event_pos =
		(uint8_t)((event_pos + 1) % AMARAN_CAPTURE_DEBUG_EVENT_RING_COUNT);
	printk("capture debug event=%u value=0x%04x fingerprint=0x%08x count=%u\n",
	       event_code, value, fingerprint, (unsigned int)debug_count);
	amaran_capture_save();
}

void amaran_capture_record_debug(uint32_t event_mask, uint8_t event_code,
				 uint16_t value)
{
	amaran_capture_record_debug_inner(event_mask, event_code, value, 0);
}

void amaran_capture_record_debug_blob(uint32_t event_mask, uint8_t event_code,
				      uint16_t value, const uint8_t *data,
				      size_t len)
{
	amaran_capture_record_debug_inner(
		event_mask, event_code, value,
		amaran_capture_fingerprint(data, len));
}

void amaran_capture_record_capabilities(uint16_t algorithms,
					uint8_t public_key_type,
					uint8_t oob_type)
{
	amaran_capture_init();
	amaran_capture_state.reserved[AMARAN_CAPTURE_DEBUG_CAPS_ALGORITHM_OFFSET] =
		(uint8_t)(algorithms & 0xff);
	amaran_capture_state.reserved[AMARAN_CAPTURE_DEBUG_CAPS_PUBLIC_KEY_OFFSET] =
		public_key_type;
	amaran_capture_state.reserved[AMARAN_CAPTURE_DEBUG_CAPS_OOB_TYPE_OFFSET] =
		oob_type;
	printk("capture capabilities algorithms=0x%04x public_key=%u oob=0x%02x\n",
	       algorithms, public_key_type, oob_type);
	amaran_capture_save();
}

void amaran_capture_record_start(uint8_t algorithm, uint8_t public_key,
				 uint8_t auth_method, uint8_t auth_action,
				 uint8_t auth_size)
{
	amaran_capture_init();
	amaran_capture_state.reserved[AMARAN_CAPTURE_DEBUG_START_ALGORITHM_OFFSET] =
		algorithm;
	amaran_capture_state.reserved[AMARAN_CAPTURE_DEBUG_START_PUBLIC_KEY_OFFSET] =
		public_key;
	amaran_capture_state.reserved[AMARAN_CAPTURE_DEBUG_START_AUTH_METHOD_OFFSET] =
		auth_method;
	amaran_capture_state.reserved[AMARAN_CAPTURE_DEBUG_START_AUTH_ACTION_OFFSET] =
		auth_action;
	amaran_capture_state.reserved[AMARAN_CAPTURE_DEBUG_START_AUTH_SIZE_OFFSET] =
		auth_size;
	printk("capture start algorithm=%u public_key=%u auth_method=%u action=%u size=%u\n",
	       algorithm, public_key, auth_method, auth_action, auth_size);
	amaran_capture_save();
}

static void attention_on(const struct bt_mesh_model *model)
{
	ARG_UNUSED(model);
	printk("attention on\n");
}

static void attention_off(const struct bt_mesh_model *model)
{
	ARG_UNUSED(model);
	printk("attention off\n");
}

static const struct bt_mesh_health_srv_cb health_cb = {
	.attn_on = attention_on,
	.attn_off = attention_off,
};

static struct bt_mesh_health_srv health_srv = {
	.cb = &health_cb,
};

BT_MESH_HEALTH_PUB_DEFINE(health_pub, 0);

static int ignored_sig_msg(const struct bt_mesh_model *model,
			   struct bt_mesh_msg_ctx *ctx,
			   struct net_buf_simple *buf)
{
	ARG_UNUSED(model);
	printk("sig model msg src=0x%04x app_idx=0x%03x len=%u\n",
	       ctx->addr, ctx->app_idx, buf->len);
	return 0;
}

static int telink_vendor_msg(const struct bt_mesh_model *model,
			     struct bt_mesh_msg_ctx *ctx,
			     struct net_buf_simple *buf)
{
	ARG_UNUSED(model);
	printk("vendor 0x0211:0x0000 opcode=0x26 src=0x%04x app_idx=0x%03x len=%u\n",
	       ctx->addr, ctx->app_idx, buf->len);
	return 0;
}

static const struct bt_mesh_model_op ignored_sig_ops[] = {
	{ BT_MESH_MODEL_OP_2(0x82, 0x01), BT_MESH_LEN_MIN(0), ignored_sig_msg },
	BT_MESH_MODEL_OP_END,
};

static const struct bt_mesh_model_op vendor_ops[] = {
	{ AMARAN_VENDOR_OPCODE, BT_MESH_LEN_MIN(0), telink_vendor_msg },
	BT_MESH_MODEL_OP_END,
};

static const struct bt_mesh_model sig_models[] = {
	BT_MESH_MODEL_CFG_SRV,
	BT_MESH_MODEL_HEALTH_SRV(&health_srv, &health_pub),
	BT_MESH_MODEL(BT_MESH_MODEL_ID_GEN_ONOFF_SRV, ignored_sig_ops, NULL, NULL),
	BT_MESH_MODEL(BT_MESH_MODEL_ID_GEN_LEVEL_SRV, ignored_sig_ops, NULL, NULL),
	BT_MESH_MODEL(BT_MESH_MODEL_ID_GEN_DEF_TRANS_TIME_SRV, ignored_sig_ops, NULL, NULL),
	BT_MESH_MODEL(BT_MESH_MODEL_ID_LIGHT_LIGHTNESS_SRV, ignored_sig_ops, NULL, NULL),
	BT_MESH_MODEL(BT_MESH_MODEL_ID_LIGHT_LIGHTNESS_SETUP_SRV, ignored_sig_ops, NULL, NULL),
	BT_MESH_MODEL(BT_MESH_MODEL_ID_LIGHT_CTL_SRV, ignored_sig_ops, NULL, NULL),
	BT_MESH_MODEL(BT_MESH_MODEL_ID_LIGHT_CTL_SETUP_SRV, ignored_sig_ops, NULL, NULL),
	BT_MESH_MODEL(BT_MESH_MODEL_ID_LIGHT_CTL_TEMP_SRV, ignored_sig_ops, NULL, NULL),
};

static const struct bt_mesh_model vendor_models[] = {
	BT_MESH_MODEL_VND(AMARAN_COMPANY_ID, AMARAN_VENDOR_MODEL_ID, vendor_ops, NULL, NULL),
};

static const struct bt_mesh_elem elements[] = {
	BT_MESH_ELEM(0, sig_models, vendor_models),
};

static const struct bt_mesh_comp comp = {
	.cid = AMARAN_COMPANY_ID,
	.pid = AMARAN_PRODUCT_ID,
	.vid = AMARAN_VERSION_ID,
	.elem = elements,
	.elem_count = ARRAY_SIZE(elements),
};

static void prov_complete(uint16_t net_idx, uint16_t addr)
{
	printk("provisioned net_idx=0x%03x addr=0x%04x\n", net_idx, addr);
}

static void prov_reset(void)
{
	printk("provisioning reset\n");
	bt_mesh_prov_enable(BT_MESH_PROV_ADV | BT_MESH_PROV_GATT);
}

static const struct bt_mesh_prov prov = {
	.uuid = dev_uuid,
	.complete = prov_complete,
	.reset = prov_reset,
};

static void bt_ready(int err)
{
	if (err) {
		printk("Bluetooth init failed err=%d\n", err);
		return;
	}

	printk("Bluetooth initialized\n");

	err = bt_set_name(CONFIG_BT_DEVICE_NAME);
	if (err) {
		printk("Bluetooth name set failed err=%d\n", err);
	}

	err = bt_mesh_init(&prov, &comp);
	if (err) {
		printk("Mesh init failed err=%d\n", err);
		return;
	}

	if (IS_ENABLED(CONFIG_SETTINGS)) {
		settings_load();
	}

	if (!bt_mesh_is_provisioned()) {
		err = bt_mesh_prov_enable(BT_MESH_PROV_ADV | BT_MESH_PROV_GATT);
		if (err) {
			printk("Provisioning enable failed err=%d\n", err);
			return;
		}
		printk("Unprovisioned beacon enabled\n");
	} else {
		printk("Already provisioned\n");
	}
}

int main(void)
{
	int err;
	bool clear_capture = amaran_capture_state.magic == AMARAN_CAPTURE_CLEAR_MAGIC;

	amaran_capture_init();
	if (IS_ENABLED(CONFIG_SETTINGS)) {
		err = settings_register(&amaran_capture_settings);
		if (err) {
			printk("capture settings register failed err=%d\n", err);
		}
	}
	if (clear_capture) {
		amaran_capture_save();
		printk("capture cleared\n");
	}
	printk("sidus join probe boot\n");

	if (strlen(AMARAN_PROBE_UUID_STRING) == sizeof(dev_uuid)) {
		memcpy(dev_uuid, AMARAN_PROBE_UUID_STRING, sizeof(dev_uuid));
	} else {
		err = hwinfo_get_device_id(dev_uuid, sizeof(dev_uuid));
		if (err < 0) {
			memset(dev_uuid, 0, sizeof(dev_uuid));
			dev_uuid[0] = 0x60;
			dev_uuid[1] = 0x0a;
		}

		dev_uuid[0] = 0x60;
		dev_uuid[1] = 0x0a;
		dev_uuid[2] = 0x52;
		dev_uuid[3] = 0x8f;
	}

	printk("device uuid prefix %02x%02x%02x%02x\n",
	       dev_uuid[0], dev_uuid[1], dev_uuid[2], dev_uuid[3]);

	amaran_probe_set_identity_from_manufacturer_data();

	err = bt_enable(bt_ready);
	if (err) {
		printk("Bluetooth enable failed err=%d\n", err);
	}

	return 0;
}
