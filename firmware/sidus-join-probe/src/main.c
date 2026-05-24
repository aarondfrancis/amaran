/*
 * Minimal Sidus join probe for nRF52840 DK.
 *
 * This is intentionally a fake provisionee. It exposes enough Bluetooth Mesh
 * identity to test whether Sidus Link Pro will provision it into an existing
 * studio mesh. It must not print or persist captured keys outside the mesh
 * stack without an explicit key-handling path.
 */

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/mesh.h>
#include <zephyr/device.h>
#include <zephyr/drivers/hwinfo.h>
#include <zephyr/settings/settings.h>
#include <zephyr/sys/byteorder.h>
#include <zephyr/sys/printk.h>

#define AMARAN_COMPANY_ID 0x0211
#define AMARAN_PRODUCT_ID 0x0000
#define AMARAN_VERSION_ID 0x3333
#define AMARAN_VENDOR_MODEL_ID 0x0000
#define AMARAN_VENDOR_OPCODE BT_MESH_MODEL_OP_3(0x26, AMARAN_COMPANY_ID)

static uint8_t dev_uuid[16];

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

	err = bt_set_name("amaran 60x S");
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

	printk("sidus join probe boot\n");

	err = hwinfo_get_device_id(dev_uuid, sizeof(dev_uuid));
	if (err < 0) {
		memset(dev_uuid, 0, sizeof(dev_uuid));
		dev_uuid[0] = 0x60;
		dev_uuid[1] = 0x0a;
	}

	/* Make the UUID stable and recognizable in scanners without exposing
	 * anything secret. The remaining bytes still come from the board ID.
	 */
	dev_uuid[0] = 0x60;
	dev_uuid[1] = 0x0a;
	dev_uuid[2] = 0x52;
	dev_uuid[3] = 0x8f;

	printk("device uuid prefix %02x%02x%02x%02x\n",
	       dev_uuid[0], dev_uuid[1], dev_uuid[2], dev_uuid[3]);

	err = bt_enable(bt_ready);
	if (err) {
		printk("Bluetooth enable failed err=%d\n", err);
	}

	return 0;
}
