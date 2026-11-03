#ifndef ZEUS_COMIC_RUNTIME_H
#define ZEUS_COMIC_RUNTIME_H
#ifdef __cplusplus
extern "C" {
#endif
unsigned char *zeus_comic_decode_region(const unsigned char *bytes, unsigned long size, int x, int y, int width, int height);
float zeus_comic_mask_coverage(const unsigned char *pixels, const unsigned char *mask, int width, int height, int left, int top, int right, int bottom);
int zeus_comic_mask_owned(const unsigned char *mask, int width, int height, int left, int top, int right, int bottom, const int *boxes, int count);
int zeus_comic_neural_mask_valid(const unsigned char *pixels, const unsigned char *hints, const unsigned char *mask, int width, int height, int left, int top, int right, int bottom);
int zeus_comic_simple_background(const unsigned char *pixels, const unsigned char *mask, int width, int height, int left, int top, int right, int bottom);
int zeus_comic_balloon_lobes(const unsigned char *interior, int width, int height, const int *boxes, int count, int *owners, int *bounds);
float zeus_comic_ink_style(const unsigned char *pixels, int width, int height, const int *boxes, int count, float *output);
int zeus_comic_flat_balloon_mask(const unsigned char *paper, unsigned char *mask, int width, int height, int left, int top, int right, int bottom, const int *boxes, int count);
int zeus_comic_plate_color(const unsigned char *pixels, int image_width, int image_height, const unsigned char *paper, int width, int height, int origin_x, int origin_y, unsigned char *color);
int zeus_comic_plate_has_edge(const unsigned char *pixels, int image_width, int image_height, const unsigned char *paper, int width, int height, int origin_x, int origin_y, const int *boxes, int count);
void zeus_comic_grow_text_mask(unsigned char *mask, int width, int height, int left, int top, int right, int bottom, int radius);
float zeus_comic_ink_residue(const unsigned char *source, const unsigned char *clean, const unsigned char *mask, int width, int height, int left, int top, int right, int bottom);
unsigned long long zeus_comic_available_memory(void);
void zeus_comic_refine_text_mask(const unsigned char *pixels, const unsigned char *hints, unsigned char *mask, int width, int height, int left, int top, int right, int bottom);
void zeus_comic_inpaint_mask(const unsigned char *source, unsigned char *pixels, const unsigned char *mask, int width, int height, int left, int top, int right, int bottom);
void zeus_comic_text_mask(const unsigned char *pixels, unsigned char *mask, int width, int height, int left, int top, int right, int bottom);
void zeus_comic_inpaint_from_source(const unsigned char *source, unsigned char *pixels, int width, int height, int left, int top, int right, int bottom);
void zeus_comic_inpaint(unsigned char *pixels, int width, int height, int left, int top, int right, int bottom);
void zeus_comic_free_pixels(unsigned char *pixels);
void *zeus_comic_load(const char *path, int context, int threads);
char *zeus_comic_generate(void *handle, const char *prompt, int maximum_tokens, int (*cancelled)(void *), void *context);
void zeus_comic_free_text(char *text);
void zeus_comic_unload(void *handle);
#ifdef __cplusplus
}
#endif
#endif
