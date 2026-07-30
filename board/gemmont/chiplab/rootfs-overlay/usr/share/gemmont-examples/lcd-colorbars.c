#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define EXPECTED_FB_ID "chiplab-lcd"
#define MAX_FB_DEVICES 16

struct rgb {
	uint8_t red;
	uint8_t green;
	uint8_t blue;
};

static uint32_t channel_value(uint8_t value, struct fb_bitfield field)
{
	uint32_t maximum;

	if (field.length == 0)
		return 0;
	maximum = (1U << field.length) - 1U;
	return (((uint32_t)value * maximum + 127U) / 255U) << field.offset;
}

static uint16_t pixel_value(const struct fb_var_screeninfo *var,
			    struct rgb color)
{
	return channel_value(color.red, var->red) |
	       channel_value(color.green, var->green) |
	       channel_value(color.blue, var->blue);
}

static int open_lcd(const char *requested, char *path, size_t path_size,
		    struct fb_fix_screeninfo *fix)
{
	unsigned int index;
	int fd;

	if (requested) {
		if (snprintf(path, path_size, "%s", requested) >= (int)path_size) {
			errno = ENAMETOOLONG;
			return -1;
		}
		fd = open(path, O_RDWR);
		if (fd >= 0 && ioctl(fd, FBIOGET_FSCREENINFO, fix) == 0)
			return fd;
		if (fd >= 0)
			close(fd);
		return -1;
	}

	for (index = 0; index < MAX_FB_DEVICES; ++index) {
		if (snprintf(path, path_size, "/dev/fb%u", index) >=
		    (int)path_size)
			continue;
		fd = open(path, O_RDWR);
		if (fd < 0)
			continue;
		if (ioctl(fd, FBIOGET_FSCREENINFO, fix) == 0 &&
		    strncmp(fix->id, EXPECTED_FB_ID, sizeof(fix->id)) == 0)
			return fd;
		close(fd);
	}

	errno = ENODEV;
	return -1;
}

static struct rgb corner_color(unsigned int x, unsigned int y,
			       unsigned int width, unsigned int height,
			       struct rgb original)
{
	unsigned int marker = 32;

	if (marker * 2 > width)
		marker = width / 2;
	if (marker * 2 > height)
		marker = height / 2;

	if (x < marker && y < marker)
		return (struct rgb) { 255, 0, 0 };
	if (x + marker >= width && y < marker)
		return (struct rgb) { 0, 255, 0 };
	if (x < marker && y + marker >= height)
		return (struct rgb) { 0, 0, 255 };
	if (x + marker >= width && y + marker >= height)
		return (struct rgb) { 255, 255, 255 };

	return original;
}

int main(int argc, char **argv)
{
	static const struct rgb bars[] = {
		{ 255, 255, 255 },
		{ 255, 255,   0 },
		{   0, 255, 255 },
		{   0, 255,   0 },
		{ 255,   0, 255 },
		{ 255,   0,   0 },
		{   0,   0, 255 },
		{   0,   0,   0 },
	};
	struct fb_fix_screeninfo fix;
	struct fb_var_screeninfo var;
	const char *requested = NULL;
	uint8_t *framebuffer;
	char path[32];
	size_t map_size;
	unsigned int x;
	unsigned int y;
	int fd;

	if (argc > 2) {
		fprintf(stderr, "usage: %s [/dev/fbN]\n", argv[0]);
		return EXIT_FAILURE;
	}
	if (argc == 2)
		requested = argv[1];

	fd = open_lcd(requested, path, sizeof(path), &fix);
	if (fd < 0) {
		fprintf(stderr, "find NT35510 framebuffer: %s\n",
			strerror(errno));
		return EXIT_FAILURE;
	}
	if (ioctl(fd, FBIOGET_VSCREENINFO, &var) < 0) {
		fprintf(stderr, "%s variable-screen ioctl: %s\n", path,
			strerror(errno));
		close(fd);
		return EXIT_FAILURE;
	}
	if (var.bits_per_pixel != 16) {
		fprintf(stderr, "%s: expected RGB565 16 bpp, got %u\n", path,
			var.bits_per_pixel);
		close(fd);
		return EXIT_FAILURE;
	}

	map_size = fix.smem_len;
	framebuffer = mmap(NULL, map_size, PROT_READ | PROT_WRITE,
			   MAP_SHARED, fd, 0);
	if (framebuffer == MAP_FAILED) {
		fprintf(stderr, "mmap %s: %s\n", path, strerror(errno));
		close(fd);
		return EXIT_FAILURE;
	}

	for (y = 0; y < var.yres; ++y) {
		uint16_t *row = (uint16_t *)(framebuffer +
					     (y + var.yoffset) *
					     fix.line_length);

		for (x = 0; x < var.xres; ++x) {
			unsigned int bar = (x * (sizeof(bars) / sizeof(bars[0]))) /
					   var.xres;
			struct rgb color = bars[bar];

			if (x < 4 || y < 4 || x + 4 >= var.xres ||
			    y + 4 >= var.yres)
				color = bars[0];
			color = corner_color(x, y, var.xres, var.yres, color);
			row[x + var.xoffset] = pixel_value(&var, color);
		}
	}

	if (msync(framebuffer, map_size, MS_SYNC) < 0 || fsync(fd) < 0) {
		fprintf(stderr, "flush %s: %s\n", path, strerror(errno));
		munmap(framebuffer, map_size);
		close(fd);
		return EXIT_FAILURE;
	}

	printf("Drew NT35510 color bars on %s: %ux%u RGB565, stride %u bytes\n",
	       path, var.xres, var.yres, fix.line_length);
	munmap(framebuffer, map_size);
	close(fd);
	return EXIT_SUCCESS;
}
