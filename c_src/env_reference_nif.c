#include <erl_nif.h>
#include <string.h>

#define ID_SIZE 16
#define GC_COMMAND "gc"
#define GC_COMMAND_SIZE 2
#define MODULE_NAME_STR "Elixir.Snex.Internal.EnvReferenceNif"

struct obj_ref {
  unsigned char id[ID_SIZE];
  ErlNifPort port;
};

ErlNifResourceType *obj_ref_type;

void obj_ref_dtor(ErlNifEnv *caller_env, void *obj) {
  struct obj_ref *ref = (struct obj_ref *)obj;

  ERL_NIF_TERM id_term;
  unsigned char *data =
      enif_make_new_binary(caller_env, ID_SIZE + GC_COMMAND_SIZE, &id_term);

  memcpy(data, ref->id, ID_SIZE);
  memcpy(data + ID_SIZE, GC_COMMAND, GC_COMMAND_SIZE);

  enif_port_command(caller_env, &ref->port, NULL, id_term);
}

static ERL_NIF_TERM make_ref_nif(ErlNifEnv *env, int argc,
                                 const ERL_NIF_TERM argv[]) {
  if (argc != 2) {
    return enif_make_badarg(env);
  }

  ErlNifBinary id;
  if (!enif_inspect_binary(env, argv[0], &id)) {
    return enif_make_badarg(env);
  }

  if (id.size != ID_SIZE) {
    return enif_make_badarg(env);
  }

  ErlNifPort port_id;
  if (!enif_get_local_port(env, argv[1], &port_id)) {
    return enif_make_badarg(env);
  }

  struct obj_ref *ref =
      enif_alloc_resource(obj_ref_type, sizeof(struct obj_ref));

  memcpy(&ref->id, id.data, ID_SIZE);
  memcpy(&ref->port, &port_id, sizeof(ErlNifPort));

  ERL_NIF_TERM ref_term = enif_make_resource(env, ref);
  enif_release_resource(ref);
  return ref_term;
}

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
  obj_ref_type = enif_open_resource_type(
      env, MODULE_NAME_STR, "obj_ref", &obj_ref_dtor, ERL_NIF_RT_CREATE, NULL);

  if (obj_ref_type == NULL) {
    return 1;
  }

  return 0;
}

static ErlNifFunc nif_funcs[] = {{"make_ref", 2, make_ref_nif}};

ERL_NIF_INIT(Elixir.Snex.Internal.EnvReferenceNif, nif_funcs, load, NULL, NULL,
             NULL)
