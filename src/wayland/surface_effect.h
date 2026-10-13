#ifndef SINGULARITY_SURFACE_EFFECT_H
#define SINGULARITY_SURFACE_EFFECT_H

#include <gtk/gtk.h>
#include <stdint.h>

void singularity_surface_effect_set(GtkWidget *widget, uint32_t mode,
	int x, int y, int width, int height, uint32_t strength);

gboolean singularity_surface_effect_set_card(GtkWidget *window, GtkWidget *bin,
    GtkWidget *card, GskTransform *transform, uint32_t mode, uint32_t strength,
    gboolean visible);

gboolean singularity_widget_get_border_box(GtkWidget *widget, GskRoundedRect *box);

gboolean singularity_surface_effect_set_frame(GtkWidget *window, GtkWidget *frame,
    uint32_t mode, uint32_t strength);

gboolean singularity_surface_effect_set_shapes(GtkWidget *window, GtkWidget **shapes,
    int n_shapes, uint32_t mode, uint32_t strength);

gboolean singularity_window_set_border_widget(GtkWindow *window, GtkWidget *frame);

gboolean singularity_widget_set_visual_transform(GtkWidget *widget, GskTransform *transform);

gboolean singularity_widget_set_visual_opacity(GtkWidget *widget, double opacity);
gboolean singularity_widget_set_visual_clip(GtkWidget *widget, const GskRoundedRect *clip);

gboolean singularity_glass_supported(void);
gboolean singularity_widget_glass_accelerated(GtkWidget *widget);
gboolean singularity_widget_set_glass(GtkWidget *widget, gboolean enabled, float blur,
		float refraction, float bezel, float zoom, float saturation, float opacity);
gboolean singularity_snapshot_append_glass(GtkSnapshot *snapshot, const GskRoundedRect *shape,
		float blur, float refraction, float bezel, float zoom, float saturation, float opacity);

#endif
