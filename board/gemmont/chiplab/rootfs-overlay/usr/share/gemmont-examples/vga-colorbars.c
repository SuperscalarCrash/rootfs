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

static uint32_t pixel_value(const struct fb_var_screeninfo *var,
			    struct rgb color)
{
	return channel_value(color.red, var->red) |
	       channel_value(color.green, var->green) |
	       channel_value(color.blue, var->blue);
}

int main(void)
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
	uint8_t *framebuffer;
	size_t map_size;
	unsigned int x;
	unsigned int y;
	int fd;

	fd = open("/dev/fb0", O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "open /dev/fb0: %s\n", strerror(errno));
		return EXIT_FAILURE;
	}
	if (ioctl(fd, FBIOGET_FSCREENINFO, &fix) < 0 ||
	    ioctl(fd, FBIOGET_VSCREENINFO, &var) < 0) {
		fprintf(stderr, "framebuffer ioctl: %s\n", strerror(errno));
		close(fd);
		return EXIT_FAILURE;
	}
	if (var.bits_per_pixel != 32) {
		fprintf(stderr, "expected 32 bpp, got %u\n", var.bits_per_pixel);
		close(fd);
		return EXIT_FAILURE;
	}

	map_size = fix.smem_len;
	framebuffer = mmap(NULL, map_size, PROT_READ | PROT_WRITE,
			   MAP_SHARED, fd, 0);
	if (framebuffer == MAP_FAILED) {
		fprintf(stderr, "mmap /dev/fb0: %s\n", strerror(errno));
		close(fd);
		return EXIT_FAILURE;
	}

	for (y = 0; y < var.yres; ++y) {
		uint32_t *row = (uint32_t *)(framebuffer +
					    (y + var.yoffset) *
					    fix.line_length);

		for (x = 0; x < var.xres; ++x) {
			unsigned int bar = (x * (sizeof(bars) / sizeof(bars[0]))) /
					   var.xres;
			struct rgb color = bars[bar];

			/* A white frame makes clipping and alignment obvious. */
			if (x < 4 || y < 4 || x + 4 >= var.xres ||
			    y + 4 >= var.yres)
				color = bars[0];
			row[x + var.xoffset] = pixel_value(&var, color);
		}
	}

	printf("Drew VGA color bars on /dev/fb0: %ux%u, stride %u bytes\n",
	       var.xres, var.yres, fix.line_length);
	munmap(framebuffer, map_size);
	close(fd);
	return EXIT_SUCCESS;
}
