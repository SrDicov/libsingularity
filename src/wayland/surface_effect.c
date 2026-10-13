#define _POSIX_C_SOURCE 200809L

#include "surface_effect.h"

#include <stdlib.h>
#include <stdbool.h>
#include <math.h>
#include <string.h>
#include <wayland-client.h>
#include <gmodule.h>

#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/wayland/gdkwayland.h>
#endif

#include "singularity-blur-unstable-v1-client-protocol.h"

#ifdef GDK_WINDOWING_WAYLAND

typedef gboolean (*NativeSurfaceEffect)(GdkSurface *, int,
		const GdkRectangle *, guint);

static NativeSurfaceEffect
get_native_surface_effect(void)
{
	static gsize initialized;
	static NativeSurfaceEffect native_set;

	if (g_once_init_enter(&initialized)) {
		GModule *module = g_module_open(NULL, G_MODULE_BIND_LAZY);
		if (module) {
			g_module_symbol(module, "sit_wayland_surface_set_background_effect",
				(gpointer *)&native_set);
			g_module_close(module);
		}
		g_once_init_leave(&initialized, 1);
	}
	return native_set;
}

struct manager_probe {
	struct zsingularity_blur_manager_v1 *manager;
	uint32_t version;
};

struct surface_effect {
	struct zsingularity_blur_v1 *proxy;

	bool applied;
	uint32_t mode, strength;
	int x, y, width, height;
};

static struct zsingularity_blur_manager_v1 *cached_manager;
static struct wl_display *cached_display;
static uint32_t cached_version;
static const char *effect_data_key = "singularity-surface-effect";
static const char *effect_signal_key = "singularity-surface-effect-signal";

static void
registry_global(void *data, struct wl_registry *registry, uint32_t name,
		const char *interface, uint32_t version)
{
	struct manager_probe *probe = data;
	if (strcmp(interface,
			zsingularity_blur_manager_v1_interface.name) != 0) {
		return;
	}

	probe->version = version < 3 ? version : 3;
	probe->manager = wl_registry_bind(registry, name,
		&zsingularity_blur_manager_v1_interface, probe->version);
}

static void
registry_global_remove(void *data, struct wl_registry *registry, uint32_t name)
{
	(void)data;
	(void)registry;
	(void)name;
}

static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
	.global_remove = registry_global_remove,
};

static struct zsingularity_blur_manager_v1 *
get_manager(struct wl_display *display)
{
	if (display == cached_display) {
		return cached_manager;
	}

	struct manager_probe probe = {0};
	struct wl_event_queue *queue = wl_display_create_queue(display);
	if (!queue) {
		return NULL;
	}

	struct wl_registry *registry = wl_display_get_registry(display);
	wl_proxy_set_queue((struct wl_proxy *)registry, queue);
	wl_registry_add_listener(registry, &registry_listener, &probe);
	wl_display_roundtrip_queue(display, queue);
	if (probe.manager) {
		wl_proxy_set_queue((struct wl_proxy *)probe.manager, NULL);
	}
	wl_registry_destroy(registry);
	wl_event_queue_destroy(queue);

	cached_display = display;
	cached_manager = probe.manager;
	cached_version = probe.version;
	return cached_manager;
}

static void
destroy_surface_effect(gpointer data)
{
	struct surface_effect *effect = data;
	if (effect->proxy) {
		zsingularity_blur_v1_destroy(effect->proxy);
	}
	free(effect);
}

static void
handle_widget_unrealize(GtkWidget *widget, gpointer data)
{
	(void)data;
	struct surface_effect *effect = g_object_steal_data(
		G_OBJECT(widget), effect_data_key);
	if (effect) {
		destroy_surface_effect(effect);
	}
}

#endif

void
singularity_surface_effect_set(GtkWidget *widget, uint32_t mode,
		int x, int y, int width, int height, uint32_t strength)
{
#ifdef GDK_WINDOWING_WAYLAND
	GdkDisplay *gdk_display = gtk_widget_get_display(widget);
	if (!GDK_IS_WAYLAND_DISPLAY(gdk_display)) {
		return;
	}

	GdkSurface *gdk_surface = gtk_native_get_surface(GTK_NATIVE(widget));
	if (!gdk_surface || !GDK_IS_WAYLAND_SURFACE(gdk_surface)) {
		return;
	}

	double offset_x, offset_y;
	gtk_native_get_surface_transform(GTK_NATIVE(widget),
		&offset_x, &offset_y);
	x += (int) floor(offset_x);
	y += (int) floor(offset_y);

	NativeSurfaceEffect native_set = get_native_surface_effect();
	if (!native_set && mode == ZSINGULARITY_BLUR_V1_MODE_LIQUID) {
		mode = ZSINGULARITY_BLUR_V1_MODE_GLASS;
	}
	if (native_set) {
		GdkRectangle region = {x, y, width, height};
		native_set(gdk_surface, (int)mode,
			width > 0 && height > 0 ? &region : NULL, strength);
		return;
	}

	struct wl_display *display = gdk_wayland_display_get_wl_display(
		GDK_WAYLAND_DISPLAY(gdk_display));
	struct zsingularity_blur_manager_v1 *manager = get_manager(display);
	if (!manager) {
		return;
	}

	struct wl_surface *surface = gdk_wayland_surface_get_wl_surface(
		GDK_WAYLAND_SURFACE(gdk_surface));
	if (!surface) {
		return;
	}

	struct surface_effect *effect = g_object_get_data(
		G_OBJECT(widget), effect_data_key);
	if (!effect) {
		effect = calloc(1, sizeof(*effect));
		if (!effect) {
			return;
		}
		effect->proxy = zsingularity_blur_manager_v1_get_blur(
			manager, surface);
		if (!effect->proxy) {
			free(effect);
			return;
		}
		g_object_set_data_full(G_OBJECT(widget), effect_data_key,
			effect, destroy_surface_effect);
		if (!g_object_get_data(G_OBJECT(widget), effect_signal_key)) {
			g_signal_connect(widget, "unrealize",
				G_CALLBACK(handle_widget_unrealize), NULL);
			g_object_set_data(G_OBJECT(widget), effect_signal_key,
				GINT_TO_POINTER(1));
		}
	}

	if (effect->applied && effect->mode == mode
			&& effect->strength == strength && effect->x == x
			&& effect->y == y && effect->width == width
			&& effect->height == height) {
		return;
	}
	effect->applied = true;
	effect->mode = mode;
	effect->strength = strength;
	effect->x = x;
	effect->y = y;
	effect->width = width;
	effect->height = height;

	if (cached_version >= 2) {
		zsingularity_blur_v1_set_mode(effect->proxy, mode);
		if (cached_version >= 3) {
			zsingularity_blur_v1_set_strength(effect->proxy, strength);
		}
		if (width > 0 && height > 0) {
			struct wl_compositor *compositor =
				gdk_wayland_display_get_wl_compositor(
					GDK_WAYLAND_DISPLAY(gdk_display));
			if (compositor) {
				struct wl_region *region =
					wl_compositor_create_region(compositor);
				wl_region_add(region, x, y, width, height);
				zsingularity_blur_v1_set_region(effect->proxy, region);
				wl_region_destroy(region);
			}
		} else {
			zsingularity_blur_v1_set_region(effect->proxy, NULL);
		}
	} else {
		zsingularity_blur_v1_set_radius(effect->proxy,
			mode == 0 ? 0 : 24);
		zsingularity_blur_v1_set_noise(effect->proxy, 0);
	}
	zsingularity_blur_v1_commit(effect->proxy);
	wl_surface_commit(surface);
#else
	(void)widget;
	(void)mode;
	(void)x;
	(void)y;
	(void)width;
	(void)height;
	(void)strength;
#endif
}

#ifdef GDK_WINDOWING_WAYLAND

typedef cairo_region_t *(*NativeBorderRegion)(GtkWidget *, GtkWidget *, GskTransform *);
typedef gboolean (*NativeRegionEffect)(GdkSurface *, int,
        const cairo_region_t *, guint);
typedef gboolean (*NativeCornerRadius)(GdkSurface *, guint);

struct card_effect {
	cairo_region_t *region;
	uint32_t mode, strength;
};

static void
destroy_card_effect(gpointer data)
{
	struct card_effect *effect = data;
	cairo_region_destroy(effect->region);
	free(effect);
}

#endif

#ifdef GDK_WINDOWING_WAYLAND

static gboolean
get_region_api(NativeBorderRegion *border_region, NativeRegionEffect *set_region)
{
	static gsize initialized;
	static NativeBorderRegion native_border_region;
	static NativeRegionEffect native_set_region;
	if (g_once_init_enter(&initialized)) {
		GModule *module = g_module_open(NULL, G_MODULE_BIND_LAZY);
		if (module) {
			g_module_symbol(module, "sit_widget_create_border_region",
				(gpointer *)&native_border_region);
			g_module_symbol(module, "sit_wayland_surface_set_background_effect_region",
				(gpointer *)&native_set_region);
			g_module_close(module);
		}
		g_once_init_leave(&initialized, 1);
	}
	*border_region = native_border_region;
	*set_region = native_set_region;
	return native_border_region && native_set_region;
}

static void
set_corner_radius(GdkSurface *surface, GtkWidget **shapes, int n_shapes)
{
	static gsize initialized;
	static NativeCornerRadius native_set_radius;
	if (g_once_init_enter(&initialized)) {
		GModule *module = g_module_open(NULL, G_MODULE_BIND_LAZY);
		if (module) {
			g_module_symbol(module,
				"sit_wayland_surface_set_background_effect_corner_radius",
				(gpointer *)&native_set_radius);
			g_module_close(module);
		}
		g_once_init_leave(&initialized, 1);
	}
	if (!native_set_radius) {
		return;
	}
	float radius = 0;
	for (int i = 0; i < n_shapes; i++) {
		GskRoundedRect box;
		if (shapes[i] && gtk_widget_get_mapped(shapes[i])
				&& singularity_widget_get_border_box(shapes[i], &box)) {
			radius = fmaxf(radius, box.corner[GSK_CORNER_TOP_LEFT].width);
		}
	}
	native_set_radius(surface, (guint)roundf(radius));
}

static gboolean
apply_region(GdkSurface *surface, NativeRegionEffect set_region,
		cairo_region_t *region, uint32_t mode, uint32_t strength,
		gboolean update_input)
{
	strength = strength > 100 ? 100 : strength;
	struct card_effect *effect = g_object_get_data(G_OBJECT(surface),
		"singularity-card-effect");
	if (effect && effect->mode == mode && effect->strength == strength
			&& cairo_region_equal(effect->region, region)) {
		cairo_region_destroy(region);
		return TRUE;
	}
	if (!set_region(surface, (int)mode, region, strength)) {
		cairo_region_destroy(region);
		return FALSE;
	}
	if (update_input) {
		gdk_surface_set_input_region(surface, region);
	}
	if (!effect) {
		effect = calloc(1, sizeof(*effect));
		g_object_set_data_full(G_OBJECT(surface), "singularity-card-effect",
			effect, destroy_card_effect);
	} else {
		cairo_region_destroy(effect->region);
	}
	effect->region = region;
	effect->mode = mode;
	effect->strength = strength;
	return TRUE;
}

#endif

static gboolean
set_widget_effect(GtkWidget *window, GtkWidget *bin,
		GtkWidget *card, GskTransform *transform, uint32_t mode,
		uint32_t strength, gboolean visible, gboolean update_input)
{
#ifdef GDK_WINDOWING_WAYLAND
	NativeBorderRegion border_region;
	NativeRegionEffect set_region;
	if (!get_region_api(&border_region, &set_region) || !gtk_widget_get_mapped(window)) {
		return FALSE;
	}
	GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(window));
	if (!surface || !GDK_IS_WAYLAND_SURFACE(surface)) {
		return FALSE;
	}

	cairo_region_t *region = visible
		? border_region(card, bin, transform) : cairo_region_create();
	if (!region) {
		return FALSE;
	}
	set_corner_radius(surface, &card, 1);
	return apply_region(surface, set_region, region, mode, strength, update_input);
#else
	return FALSE;
#endif
}

gboolean
singularity_surface_effect_set_shapes(GtkWidget *window, GtkWidget **shapes,
		int n_shapes, uint32_t mode, uint32_t strength)
{
#ifdef GDK_WINDOWING_WAYLAND
	NativeBorderRegion border_region;
	NativeRegionEffect set_region;
	if (!get_region_api(&border_region, &set_region) || !gtk_widget_get_mapped(window)) {
		return FALSE;
	}
	GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(window));
	if (!surface || !GDK_IS_WAYLAND_SURFACE(surface)) {
		return FALSE;
	}

	cairo_region_t *region = cairo_region_create();
	for (int i = 0; i < n_shapes; i++) {
		if (!shapes[i] || !gtk_widget_get_mapped(shapes[i])) {
			continue;
		}
		cairo_region_t *shape = border_region(shapes[i], NULL, NULL);
		if (!shape) {
			cairo_region_destroy(region);
			return FALSE;
		}
		cairo_region_union(region, shape);
		cairo_region_destroy(shape);
	}
	set_corner_radius(surface, shapes, n_shapes);
	return apply_region(surface, set_region, region, mode, strength, FALSE);
#else
	return FALSE;
#endif
}


gboolean
singularity_surface_effect_set_card(GtkWidget *window, GtkWidget *bin,
		GtkWidget *card, GskTransform *transform, uint32_t mode,
		uint32_t strength, gboolean visible)
{
	return set_widget_effect(window, bin, card, transform, mode, strength,
		visible, TRUE);
}

gboolean
singularity_surface_effect_set_frame(GtkWidget *window, GtkWidget *frame,
		uint32_t mode, uint32_t strength)
{
	return set_widget_effect(window, frame, frame, NULL, mode, strength,
		TRUE, FALSE);
}

gboolean
singularity_widget_get_border_box(GtkWidget *widget, GskRoundedRect *box)
{
	typedef void (*NativeBorderBox)(GtkWidget *, GskRoundedRect *);
	static gsize initialized;
	static NativeBorderBox border_box;
	if (g_once_init_enter(&initialized)) {
		GModule *module = g_module_open(NULL, G_MODULE_BIND_LAZY);
		if (module) {
			g_module_symbol(module, "sit_widget_get_border_box",
				(gpointer *)&border_box);
			g_module_close(module);
		}
		g_once_init_leave(&initialized, 1);
	}
	if (!border_box) {
		return FALSE;
	}
	border_box(widget, box);
	return TRUE;
}


gboolean
singularity_window_set_border_widget(GtkWindow *window, GtkWidget *frame)
{
	typedef gboolean (*NativeBorderWidget)(GtkWindow *, GtkWidget *);
	static gsize initialized;
	static NativeBorderWidget set_border;
	if (g_once_init_enter(&initialized)) {
		GModule *module = g_module_open(NULL, G_MODULE_BIND_LAZY);
		if (module) {
			g_module_symbol(module, "sit_window_set_border_widget",
				(gpointer *)&set_border);
			g_module_close(module);
		}
		g_once_init_leave(&initialized, 1);
	}
	return set_border ? set_border(window, frame) : FALSE;
}

gboolean
singularity_widget_set_visual_transform(GtkWidget *widget, GskTransform *transform)
{
	typedef gboolean (*NativeTransform)(GtkWidget *, GskTransform *);
	static gsize initialized;
	static NativeTransform set_transform;
	if (g_once_init_enter(&initialized)) {
		GModule *module = g_module_open(NULL, G_MODULE_BIND_LAZY);
		if (module) {
			g_module_symbol(module, "sit_widget_set_visual_transform",
				(gpointer *)&set_transform);
			g_module_close(module);
		}
		g_once_init_leave(&initialized, 1);
	}
	return set_transform ? set_transform(widget, transform) : FALSE;
}

gboolean
singularity_widget_set_visual_opacity(GtkWidget *widget, double opacity)
{
	typedef gboolean (*NativeVisual)(GtkWidget *, double);
	static gsize initialized;
	static NativeVisual set_visual;
	if (g_once_init_enter(&initialized)) {
		GModule *module = g_module_open(NULL, G_MODULE_BIND_LAZY);
		if (module) {
			g_module_symbol(module, "sit_widget_set_visual_opacity",
				(gpointer *)&set_visual);
			g_module_close(module);
		}
		g_once_init_leave(&initialized, 1);
	}
	return set_visual ? set_visual(widget, opacity) : FALSE;
}

gboolean
singularity_widget_set_visual_clip(GtkWidget *widget, const GskRoundedRect * clip)
{
	typedef gboolean (*NativeVisual)(GtkWidget *, const GskRoundedRect *);
	static gsize initialized;
	static NativeVisual set_visual;
	if (g_once_init_enter(&initialized)) {
		GModule *module = g_module_open(NULL, G_MODULE_BIND_LAZY);
		if (module) {
			g_module_symbol(module, "sit_widget_set_visual_clip",
				(gpointer *)&set_visual);
			g_module_close(module);
		}
		g_once_init_leave(&initialized, 1);
	}
	return set_visual ? set_visual(widget, clip) : FALSE;
}

typedef struct {
	float blur;
	float refraction;
	float bezel;
	float zoom;
	float saturation;
	float opacity;
} NativeGlass;

typedef gboolean (*NativeWidgetGlass)(GtkWidget *, const NativeGlass *);
typedef void (*NativeSnapshotGlass)(GtkSnapshot *, const GskRoundedRect *, const NativeGlass *);

typedef gboolean (*NativeGlassAccelerated)(GtkWidget *);

static NativeWidgetGlass native_widget_glass;
static NativeSnapshotGlass native_snapshot_glass;
static NativeGlassAccelerated native_glass_accelerated;

static void
load_native_glass(void)
{
	static gsize initialized;
	if (g_once_init_enter(&initialized)) {
		GModule *module = g_module_open(NULL, G_MODULE_BIND_LAZY);
		if (module) {
			g_module_symbol(module, "sit_widget_set_glass",
				(gpointer *)&native_widget_glass);
			g_module_symbol(module, "sit_snapshot_append_glass",
				(gpointer *)&native_snapshot_glass);
			g_module_symbol(module, "sit_widget_get_glass_accelerated",
				(gpointer *)&native_glass_accelerated);
			g_module_close(module);
		}
		g_once_init_leave(&initialized, 1);
	}
}

gboolean
singularity_glass_supported(void)
{
	load_native_glass();
	return native_widget_glass != NULL && native_snapshot_glass != NULL;
}

gboolean
singularity_widget_glass_accelerated(GtkWidget *widget)
{
	load_native_glass();
	if (!native_widget_glass)
		return FALSE;
	return native_glass_accelerated ? native_glass_accelerated(widget) : TRUE;
}

gboolean
singularity_widget_set_glass(GtkWidget *widget, gboolean enabled, float blur,
		float refraction, float bezel, float zoom, float saturation, float opacity)
{
	NativeGlass glass = { blur, refraction, bezel, zoom, saturation, opacity };
	load_native_glass();
	if (!native_widget_glass)
		return FALSE;
	return native_widget_glass(widget, enabled ? &glass : NULL);
}

gboolean
singularity_snapshot_append_glass(GtkSnapshot *snapshot, const GskRoundedRect *shape,
		float blur, float refraction, float bezel, float zoom, float saturation, float opacity)
{
	NativeGlass glass = { blur, refraction, bezel, zoom, saturation, opacity };
	load_native_glass();
	if (!native_snapshot_glass)
		return FALSE;
	native_snapshot_glass(snapshot, shape, &glass);
	return TRUE;
}
