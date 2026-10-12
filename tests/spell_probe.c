#define _GNU_SOURCE
#include <dlfcn.h>
#include <enchant.h>
#include <stddef.h>
#include <glib.h>

#include "spell_probe.h"

static unsigned checks;

unsigned
singularity_spell_test_count (void)
{
  return checks;
}

void
singularity_spell_test_reset (void)
{
  checks = 0;
}

int
enchant_dict_check (EnchantDict *dict, const char *const word, ssize_t length)
{
  static int (*check) (EnchantDict *, const char *const, ssize_t);

  if (check == NULL)
    {
      check = dlsym (RTLD_NEXT, "enchant_dict_check");
      if (check == NULL)
        g_error ("Cannot resolve the installed Enchant dictionary checker");
    }
  checks++;
  return check (dict, word, length);
}
