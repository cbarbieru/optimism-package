_ethereum_package_cl_context = import_module(
    "github.com/ethpandaops/ethereum-package/src/cl/cl_context.star"
)

_ethereum_package_constants = import_module(
    "github.com/ethpandaops/ethereum-package/src/package_io/constants.star"
)

_ethereum_package_input_parser = import_module(
    "github.com/ethpandaops/ethereum-package/src/package_io/input_parser.star"
)

_constants = import_module("../../package_io/constants.star")
_observability = import_module("../../observability/observability.star")

_util = import_module("../../util.star")

_net = import_module("/src/util/net.star")

#  ---------------------------------- Beacon client -------------------------------------

# The Docker container runs as the "hildr" user so we can't write to root
BEACON_DATA_DIRPATH_ON_SERVICE_CONTAINER = "/data/hildr/hildr-beacon-data"

METRICS_PATH = "/metrics"

# TODO This block seems repetitive, at least for all OP services
VERBOSITY_LEVELS = {
    _ethereum_package_constants.GLOBAL_LOG_LEVEL.error: "ERROR",
    _ethereum_package_constants.GLOBAL_LOG_LEVEL.warn: "WARN",
    _ethereum_package_constants.GLOBAL_LOG_LEVEL.info: "INFO",
    _ethereum_package_constants.GLOBAL_LOG_LEVEL.debug: "DEBUG",
    _ethereum_package_constants.GLOBAL_LOG_LEVEL.trace: "TRACE",
}


def launch(
    plan,
    params,
    network_params,
    jwt_file,
    deployment_output,
    is_sequencer,
    log_level,
    persistent,
    tolerations,
    node_selectors,
    el_context,
    cl_contexts,
    l1_config_env_vars,
    observability_helper,
):
    cl_log_level = _ethereum_package_input_parser.get_client_log_level_or_default(
        params.log_level, log_level, VERBOSITY_LEVELS
    )

    cl_node_selectors = _ethereum_package_input_parser.get_client_node_selectors(
        params.node_selectors,
        node_selectors,
    )

    cl_tolerations = _ethereum_package_input_parser.get_client_tolerations(
        params.tolerations, [], tolerations
    )

    config = get_service_config(
        plan=plan,
        params=params,
        network_params=network_params,
        jwt_file=jwt_file,
        deployment_output=deployment_output,
        is_sequencer=is_sequencer,
        log_level=cl_log_level,
        persistent=persistent,
        tolerations=cl_tolerations,
        node_selectors=cl_node_selectors,
        el_context=el_context,
        cl_contexts=cl_contexts,
        l1_config_env_vars=l1_config_env_vars,
        observability_helper=observability_helper,
    )

    service = plan.add_service(params.service_name, config)

    rpc_port = params.ports[_net.RPC_PORT_NAME]
    service_url = _net.service_url(params.service_name, rpc_port)

    metrics_info = _observability.new_metrics_info(
        observability_helper, service, METRICS_PATH
    )

    return struct(
        service=service,
        # TODO This may be deprecated as soon as we update the codebase to use the precalculated input params
        context=_ethereum_package_cl_context.new_cl_context(
            client_name="hildr",
            enr="",  # beacon_node_enr,
            ip_addr=service.ip_address,
            http_port=rpc_port.number,
            beacon_http_url=service_url,
            cl_nodes_metrics_info=[metrics_info],
            beacon_service_name=params.service_name,
        ),
    )


def get_service_config(
    plan,
    params,
    network_params,
    deployment_output,
    is_sequencer,
    jwt_file,
    log_level,
    persistent,
    tolerations,
    node_selectors,
    el_context,
    cl_contexts,
    l1_config_env_vars,
    observability_helper,
):
    EXECUTION_ENGINE_ENDPOINT = _util.make_execution_engine_url(el_context)
    EXECUTION_RPC_ENDPOINT = _util.make_execution_rpc_url(el_context)

    ports = _net.ports_to_port_specs(params.ports)

    cmd = [
        "--devnet",
        "--log-level={}".format(log_level),
        "--jwt-file={}".format(_ethereum_package_constants.JWT_MOUNT_PATH_ON_CONTAINER),
        "--l1-beacon-url={0}".format(l1_config_env_vars["CL_RPC_URL"]),
        "--l1-rpc-url={0}".format(l1_config_env_vars["L1_RPC_URL"]),
        "--l1-ws-rpc-url={0}".format(l1_config_env_vars["L1_WS_URL"]),
        "--l2-engine-url={0}".format(EXECUTION_ENGINE_ENDPOINT),
        "--l2-rpc-url={0}".format(EXECUTION_RPC_ENDPOINT),
        "--rpc-addr=0.0.0.0",
        "--rpc-port={0}".format(params.ports[_net.RPC_PORT_NAME].number),
        "--sync-mode=full",
        "--network="
        + "{0}/rollup-{1}.json".format(
            _ethereum_package_constants.GENESIS_DATA_MOUNTPOINT_ON_CLIENTS,
            network_params.network_id,
        ),
        # TODO: support altda flags once they are implemented.
        # See https://github.com/optimism-java/hildr/issues/134
        # eg: "--altda.enabled=" + str(da_server_context.enabled),
    ]

    # configure files

    files = {
        _ethereum_package_constants.GENESIS_DATA_MOUNTPOINT_ON_CLIENTS: deployment_output,
        _ethereum_package_constants.JWT_MOUNTPOINT_ON_CLIENTS: jwt_file,
    }
    if persistent:
        files[BEACON_DATA_DIRPATH_ON_SERVICE_CONTAINER] = Directory(
            persistent_key="data-{0}".format(params.service_name),
            size=int(params.volume_size)
            if int(params.volume_size) > 0
            else _constants.VOLUME_SIZE[network_params.network][
                _constants.CL_TYPE.hildr + "_volume_size"
            ],
        )

    # apply customizations

    if observability_helper.enabled:
        cmd += [
            "--metrics-enable",
            "--metrics-port={0}".format(_observability.METRICS_PORT_NUM),
        ]

        _observability.expose_metrics_port(ports)

    if is_sequencer:
        cmd.append("--sequencer-enable")

    if len(cl_contexts) > 0:
        cmd.append(
            "--disc-boot-nodes="
            + ",".join(
                [
                    ctx.enr
                    for ctx in cl_contexts[
                        : _ethereum_package_constants.MAX_ENR_ENTRIES
                    ]
                ]
            )
        )

    cmd += params.extra_params

    config_args = {
        "image": params.image,
        "ports": ports,
        "cmd": cmd,
        "files": files,
        "private_ip_address_placeholder": _ethereum_package_constants.PRIVATE_IP_ADDRESS_PLACEHOLDER,
        "env_vars": params.extra_env_vars,
        "labels": params.labels,
        "tolerations": tolerations,
        "node_selectors": node_selectors,
    }

    # configure resources

    if params.min_cpu > 0:
        config_args["min_cpu"] = params.min_cpu
    if params.max_cpu > 0:
        config_args["max_cpu"] = params.max_cpu
    if params.min_mem > 0:
        config_args["min_memory"] = params.min_mem
    if params.max_mem > 0:
        config_args["max_memory"] = params.max_mem

    return ServiceConfig(**config_args)
