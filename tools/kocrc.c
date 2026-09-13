// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Bouteillepleine
// Print the symbol CRCs of a kernel module.
//   kocrc -e mod.ko   what it EXPORTS   (__crc_<sym> entries in .symtab)
//   kocrc -i mod.ko   what it IMPORTS   (the __versions section)
// Output is "<crc8hex> <symbol>" per line, sorted by nothing in particular.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <elf.h>

static unsigned char *slurp(const char *p, long *n)
{
	FILE *f = fopen(p, "rb");
	if (!f) return NULL;
	fseek(f, 0, SEEK_END); *n = ftell(f); fseek(f, 0, SEEK_SET);
	unsigned char *b = malloc(*n);
	if (!b || fread(b, 1, *n, f) != (size_t)*n) { free(b); fclose(f); return NULL; }
	fclose(f);
	return b;
}

int main(int argc, char **argv)
{
	if (argc != 3 || argv[1][0] != '-' ||
	    (argv[1][1] != 'e' && argv[1][1] != 'i')) {
		fprintf(stderr, "usage: kocrc -e|-i <module.ko>\n");
		return 2;
	}
	long n;
	unsigned char *d = slurp(argv[2], &n);
	if (!d) { fprintf(stderr, "kocrc: cannot read %s\n", argv[2]); return 1; }
	if (n < (long)sizeof(Elf64_Ehdr) || memcmp(d, ELFMAG, SELFMAG) ||
	    d[EI_CLASS] != ELFCLASS64) {
		fprintf(stderr, "kocrc: %s is not a 64-bit ELF\n", argv[2]); return 1;
	}
	Elf64_Ehdr *eh = (Elf64_Ehdr *)d;
	Elf64_Shdr *sh = (Elf64_Shdr *)(d + eh->e_shoff);
	const char *shstr = (const char *)(d + sh[eh->e_shstrndx].sh_offset);
	int found = 0;

	for (int i = 0; i < eh->e_shnum; i++) {
		if (argv[1][1] == 'i') {
			if (strcmp(shstr + sh[i].sh_name, "__versions")) continue;
			// struct modversion_info { unsigned long crc; char name[56]; }
			for (Elf64_Xword o = 0; o + 64 <= sh[i].sh_size; o += 64) {
				unsigned char *e = d + sh[i].sh_offset + o;
				printf("%08x %.56s\n", *(unsigned int *)e, (char *)e + 8);
				found = 1;
			}
		} else {
			if (sh[i].sh_type != SHT_SYMTAB) continue;
			Elf64_Sym *sym = (Elf64_Sym *)(d + sh[i].sh_offset);
			const char *str = (const char *)(d + sh[sh[i].sh_link].sh_offset);
			for (Elf64_Xword k = 0; k < sh[i].sh_size / sizeof(Elf64_Sym); k++) {
				const char *nm = str + sym[k].st_name;
				if (strncmp(nm, "__crc_", 6)) continue;
				unsigned int crc;
				Elf64_Section ndx = sym[k].st_shndx;
				// CONFIG_MODULE_REL_CRCS (6.x): __crc_<sym> is defined in
				// __kcrctab and st_value is an offset into it, not the CRC.
				// Without this the values read out as 4, 0x70, 0xd4 ... and
				// every comparison 'fails'. Older builds keep the CRC in
				// st_value itself (SHN_ABS).
				if (ndx < eh->e_shnum &&
				    !strncmp(shstr + sh[ndx].sh_name, "__kcrctab", 9) &&
				    sym[k].st_value + 4 <= sh[ndx].sh_size)
					crc = *(unsigned int *)(d + sh[ndx].sh_offset + sym[k].st_value);
				else
					crc = (unsigned int)sym[k].st_value;
				printf("%08x %s\n", crc, nm + 6);
				found = 1;
			}
		}
	}
	free(d);
	if (!found) { fprintf(stderr, "kocrc: nothing found in %s\n", argv[2]); return 1; }
	return 0;
}
