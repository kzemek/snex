#include <erl_nif.h>
#include <stdatomic.h>
#include <string.h>

#define GARBAGE_COLLECTOR_NAME "Elixir.Snex.Internal.GarbageCollector"
#define MODULE_NAME_STR "Elixir.Snex.Internal.EnvReferenceNif"

struct obj_ref {
  ERL_NIF_TERM snex_env;
  ErlNifEnv *env;
  atomic_flag gc_disabled;
};

struct priv_data {
  ErlNifResourceType *obj_ref_type;
  ERL_NIF_TERM garbage_collector_name;
  ERL_NIF_TERM atom_nil;
};

static void obj_ref_dtor(ErlNifEnv *caller_env, void *obj) {
  struct obj_ref *ref = (struct obj_ref *)obj;
  struct priv_data *priv = enif_priv_data(caller_env);

  if (atomic_flag_test_and_set(&ref->gc_disabled)) {
    goto cleanup;
  }

  ErlNifPid garbage_collector_pid;
  if (!enif_whereis_pid(caller_env, priv->garbage_collector_name,
                        &garbage_collector_pid)) {
    // Silently ignored as this will often be the case on node shutdown.
    // Garbage collector crashes will be logged elsewhere anyway.
    goto cleanup;
  }

  if (!enif_send(caller_env, &garbage_collector_pid, ref->env, ref->snex_env)) {
    fprintf(stderr, "Failed to send garbage collection message\n");
    goto cleanup;
  }

cleanup:
  enif_free_env(ref->env);
}

static ERL_NIF_TERM make_ref_nif(ErlNifEnv *env, int argc,
                                 const ERL_NIF_TERM argv[]) {
  if (argc != 1) {
    goto badarg;
  }

  ErlNifEnv *ref_env = enif_alloc_env();
  if (ref_env == NULL) {
    goto badarg;
  }

  struct priv_data *priv = enif_priv_data(env);
  struct obj_ref *ref =
      enif_alloc_resource(priv->obj_ref_type, sizeof(struct obj_ref));
  if (ref == NULL) {
    goto enif_free_env;
  }

  *ref = (struct obj_ref){
      .env = ref_env,
      .snex_env = enif_make_copy(ref_env, argv[0]),
      .gc_disabled = ATOMIC_FLAG_INIT,
  };

  ERL_NIF_TERM ref_term = enif_make_resource(env, ref);
  enif_release_resource(ref);
  return ref_term;

enif_free_env:
  enif_free_env(ref_env);
badarg:
  return enif_make_badarg(env);
}

static ERL_NIF_TERM disable_gc_nif(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
  if (argc != 1) {
    goto badarg;
  }

  struct priv_data *priv = enif_priv_data(env);
  struct obj_ref *ref;
  if (!enif_get_resource(env, argv[0], priv->obj_ref_type, (void **)&ref)) {
    // Silently ignore, as this will often be the case when we try to disable GC
    // again - the original resource might have been garbage collected already.
    return priv->atom_nil;
  }

  atomic_flag_test_and_set(&ref->gc_disabled);
  return priv->atom_nil;

badarg:
  return enif_make_badarg(env);
}

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
  (void)load_info;

  struct priv_data *priv = enif_alloc(sizeof(struct priv_data));
  if (priv == NULL) {
    goto error;
  }

  priv->obj_ref_type = enif_open_resource_type(
      env, MODULE_NAME_STR, "obj_ref", &obj_ref_dtor, ERL_NIF_RT_CREATE, NULL);
  if (priv->obj_ref_type == NULL) {
    goto enif_free_priv;
  }

  priv->garbage_collector_name = enif_make_atom(env, GARBAGE_COLLECTOR_NAME);
  priv->atom_nil = enif_make_atom(env, "nil");

  *priv_data = priv;
  return 0;

enif_free_priv:
  enif_free(priv);
error:
  return 1;
}

static ErlNifFunc nif_funcs[] = {{"make_ref", 1, make_ref_nif, 0},
                                 {"disable_gc", 1, disable_gc_nif, 0}};

ERL_NIF_INIT(Elixir.Snex.Internal.EnvReferenceNif, nif_funcs, load, NULL, NULL,
             NULL)
