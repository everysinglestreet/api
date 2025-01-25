
"""
    best_route_xml(user_id, city_name, src::LLA, dst::LLA)

Take the underlying graph data from `joinpath(DATA_FOLDER, "city_data", "{user_id}", "{city_name}_graph.jld2")`
and compute the best route using astar.
Return an XMLDocument for the best route from src to dst.
"""
function best_route_xml(user_id, city_name, src::LLA, dst::LLA)
    g_path = joinpath(DATA_FOLDER, "city_data", "$user_id", "$(city_name)_graph.jld2")
    graph_data = load(g_path)
    lla_points = EverySingleStreet.best_route(graph_data, src, dst)
    return EverySingleStreet.create_gpx_document(lla_points)
end