
// Copyright (c) 2013-2014 Quanta Research Cambridge, Inc.

// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

#include <stdio.h>
#include <stdint.h>
#include <errno.h>
#include <assert.h>
#include <sys/mman.h>
#include <stdlib.h>
#include "sock_utils.h"

#define MAX_DMA_PORTS    4
#define MAX_DMA_IDS     32
typedef struct {
    unsigned char *buffer;
    uint32_t buffer_len;
    int size_accum;
} DMAINFO[MAX_DMA_IDS];
static DMAINFO dma_info[MAX_DMA_PORTS];
static int dma_trace;// = 1;

extern "C" void write_pareff32(uint32_t pref, uint32_t offset, unsigned int data)
{
    uint32_t id = pref>>5;
    pref -= id<<5; 
    if (dma_trace)
      fprintf(stderr, "%s: %d %d %d\n", __FUNCTION__, id, pref, offset);
    *(unsigned int *)&dma_info[id][pref].buffer[offset] = data;
}

extern "C" unsigned int read_pareff32(uint32_t pref, uint32_t offset)
{
    uint32_t id = pref>>5;
    pref -= id<<5; 
    if (dma_trace)
      fprintf(stderr, "%s: %d %d %d\n", __FUNCTION__, id, pref, offset);
    return *(unsigned int *)&dma_info[id][pref].buffer[offset];
}

extern "C" void write_pareff64(uint32_t pref, uint32_t offset, uint64_t data)
{
    uint32_t id = pref>>5;
    pref -= id<<5; 
    if (dma_trace)
      fprintf(stderr, "%s: %d %d %d\n", __FUNCTION__, id, pref, offset);
    *(uint64_t *)&dma_info[id][pref].buffer[offset] = data;
}

extern "C" uint64_t read_pareff64(uint32_t pref, uint32_t offset)
{
    uint32_t id = pref>>5;
    pref -= id<<5; 
    if (dma_trace)
      fprintf(stderr, "%s: %d %d %d\n", __FUNCTION__, id, pref, offset);
    return *(uint64_t *)&dma_info[id][pref].buffer[offset];
}

extern "C" void pareff_init(uint32_t id, uint32_t pref, uint32_t size)
{
    if (dma_trace)
      fprintf(stderr, "pareff_init: id=%d pref=%d, size=%08x size_accum=%08x\n", id, pref, size, dma_info[id][pref].size_accum);
    assert(pref < MAX_DMA_IDS);
    dma_info[id][pref].size_accum += size;
    if(size == 0){
      int fd;
      pareff_fd(&fd);
      dma_info[id][pref].buffer = (unsigned char *)mmap(0,
          dma_info[id][pref].size_accum, PROT_WRITE|PROT_WRITE|PROT_EXEC, MAP_SHARED, fd, 0);
      if (dma_info[id][pref].buffer == MAP_FAILED) {
	fprintf(stderr, "pareff_init: mmap failed fd %x buffer %p size %x errno %d\n", fd, dma_info[id][pref].buffer, size, errno);
	exit(-1);
      }
      dma_info[id][pref].buffer_len = dma_info[id][pref].size_accum;
    }
    if (dma_trace)
      fprintf(stderr, "pareff_init: done\n");
}
