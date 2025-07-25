_registry = import_module("/src/package_io/registry.star")
_filter = import_module("/src/util/filter.star")
_net = import_module("/src/util/net.star")
_id = import_module("/src/util/id.star")

_DEFAULT_ARGS = {
    "type": "op-node",
    "image": None,
    "log_level": None,
    "extra_env_vars": {},
    "extra_labels": {},
    "extra_params": [],
    "node_selectors": {},
    "tolerations": [],
    "volume_size": 0,
    "min_cpu": 0,
    "max_cpu": 0,
    "min_mem": 0,
    "max_mem": 0,
}

_IMAGE_IDS = {
    "op-node": _registry.OP_NODE,
    "kona-node": _registry.KONA_NODE,
    "hildr": _registry.HILDR,
}


def parse(args, participant_name, network_params, registry):
    return _parse(args, participant_name, network_params, registry, "cl")


def parse_builder(args, participant_name, network_params, registry):
    return _parse(args, participant_name, network_params, registry, "clbuilder")


def _parse(args, participant_name, network_params, registry, cl_kind):
    network_id = network_params.network_id
    network_name = network_params.name

    # Any extra attributes will cause an error
    _filter.assert_keys(
        args or {},
        _DEFAULT_ARGS.keys(),
        "Invalid attributes in CL configuration for "
        + participant_name
        + " on network "
        + network_name
        + ": {}",
    )

    # We filter the None values so that we can merge dicts easily
    # and merge the config with the defaults
    cl_params = _DEFAULT_ARGS | _filter.remove_none(args or {})

    # We default the image to the one in the registry
    #
    # This step, as a side effect, also verifies the CL type
    cl_params["image"] = cl_params["image"] or _default_image(
        cl_params["type"], registry
    )

    cl_params["name"] = participant_name
    cl_params["service_name"] = "op-{}-{}-{}-{}".format(
        cl_kind, network_id, participant_name, cl_params["type"]
    )

    # Draft of what the labels could look like
    cl_params["labels"] = {
        "op.kind": cl_kind,
        "op.network.id": str(network_id),
        "op.network.participant.name": participant_name,
        "op.cl.type": cl_params["type"],
    }

    # We register the CL ports
    cl_params["ports"] = {
        _net.RPC_PORT_NAME: _net.port(number=8547),
        _net.TCP_DISCOVERY_PORT_NAME: _net.port(number=9003),
        _net.UDP_DISCOVERY_PORT_NAME: _net.port(number=9003, transport_protocol="UDP"),
    }

    return struct(**cl_params)


def _default_image(participant_type, registry):
    if participant_type in _IMAGE_IDS:
        return registry.get(_IMAGE_IDS[participant_type])
    else:
        fail("Invalid CL type: {}".format(participant_type))
