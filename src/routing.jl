
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


"""
    update_graph(user_id, city_name, city_map, walked_parts)

Update the graph saved in `joinpath(DATA_FOLDER, "city_data", "{user_id}", "{city_name}_graph.jld2")`
with the given `walked_parts`. This will make edges "longer" that are already walked as well as ways that don't count as walkable roads.
The updated graph is saved in the same path.
"""
function update_graph(user_id, city_name, city_map, walked_parts)
    g_path = joinpath(DATA_FOLDER, "city_data", "$user_id", "$(city_name)_graph.jld2")
    if !ispath(g_path)
        graph_data = EverySingleStreet.convert_to_weighted_graph(city_map)
        graph_data = Dict(
            "g" => graph_data.g, 
            "nodes" => graph_data.nodes,
            "kd_tree" => graph_data.kd_tree,
            "osm_id_to_node_id" => graph_data.osm_id_to_node_id
        )
    else 
        graph_data = load(g_path)
    end
    EverySingleStreet.update_weights!(graph_data["g"], city_map, walked_parts)
    save(g_path, graph_data)
end