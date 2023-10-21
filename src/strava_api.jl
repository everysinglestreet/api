function get_access_token(user_id)
    url = "https://www.strava.com/oauth/token"
    refresh_token = readjson(joinpath(DATA_FOLDER, "user_data", "$user_id.json"))[:refresh_token]

    payload = Dict(
        "client_id" => ENV["CLIENT_ID"],
        "client_secret" => ENV["CLIENT_SECRET"],
        "refresh_token" => refresh_token,
        "grant_type" => "refresh_token",
        "f" => "json"
    )

    r = HTTP.request("POST", url,
                    ["Content-Type" => "application/json"],
                    JSON3.write(payload))

    result = JSON3.read(String(r.body))
    return result[:access_token]
end

function get_activity_data(access_token, activity_id)
    url = "https://www.strava.com/api/v3/activities/$activity_id"

    headers = Dict("Authorization" => "Bearer $access_token", "Content-Type" => "application/json")

    r = HTTP.request("GET", url, headers)
    json_result = JSON3.read(String(r.body))
    return json_result
end

download_activity(user_id::Int, activity_id) = download_activity(user_id, get_access_token(user_id), activity_id)

function download_activity(user_id, access_token, activity_id, start_time)
    path = joinpath(DATA_FOLDER, "activities", "$user_id", "$activity_id.json")
    isfile(path) && return false
    url = "https://www.strava.com/api/v3/activities/$activity_id/streams?keys=latlng,time"

    headers = Dict("Authorization" => "Bearer $access_token", "Content-Type" => "application/json")
    r = HTTP.request("GET", url, headers)
    
    result = copy(JSON3.read(String(r.body)))
    # convert the data into our own format
    save_data = Dict{Symbol, Any}()
    for stream in result
        if stream[:type] == "latlng"
            save_data[:latlon] = stream[:data]
        elseif stream[:type] == "time"
            save_data[:times] = stream[:data] 
        end
    end

    save_data[:start_time] = start_time
    
    mkpath(dirname(path))
    open(path, "w") do io
        JSON3.pretty(io, save_data)
    end
    return true
end

function set_activity_fields(access_token, activity_id, payload)
    url = "https://www.strava.com/api/v3/activities/$activity_id"
    headers = Dict("Authorization" => "Bearer $access_token", "Content-Type" => "application/json")

    r = HTTP.request("PUT", url,
                    headers,
                    JSON3.write(payload))

    result = JSON3.read(String(r.body))
    return result
end

function prepend_activity_description(access_token, activity_data, desc)
    current_desc = activity_data[:description]
    new_desc = desc
    if !isnothing(current_desc)
        new_desc = "$new_desc\n$current_desc"
    end
    set_activity_fields(access_token, activity_data[:id], Dict(:description => strip(new_desc)))
end

function calculate_statistics(city_map, walked_parts)
    walked_road_km = EverySingleStreet.total_length(walked_parts; filter_fct=(way)->EverySingleStreet.iswalkable_road(way))/1000
    road_km = EverySingleStreet.total_length(city_map; filter_fct=(way)->EverySingleStreet.iswalkable_road(way))/1000
    district_perc = EverySingleStreet.get_walked_district_perc(city_map, collect(values(walked_parts.ways)))
    return (walked_road_km = walked_road_km, road_km = road_km, district_percentages = district_perc)
end

function compare_statistics(before, after)
    result_dict = OrderedDict{Symbol, String}()
    before_total_perc = before.walked_road_km / before.road_km * 100
    after_total_perc = after.walked_road_km / after.road_km * 100
    if floor(Int, after_total_perc) > floor(Int, before_total_perc)
        result_dict[Symbol("Total: ")] = @sprintf "%.0f%%" after_total_perc
    end
    for (district, perc)  in after.district_percentages
        if !haskey(before.district_percentages, district)
            result_dict[Symbol("$district: ")] = @sprintf "First %.1f%%" perc
        elseif perc ÷ 5 > before.district_percentages[district] ÷ 5
            result_dict[Symbol("$district: ")] = @sprintf "> %.0f%%" perc ÷ 5 * 5
        end
    end
    return result_dict
end

function get_district_statistics(user_id)
    user_data = readjson(joinpath(DATA_FOLDER, "user_data", "$user_id.json"))
    city_data_path = joinpath(DATA_FOLDER, "city_data", "$user_id", "$(user_data[:city_name]).jld2")
    city_walked_path = joinpath(DATA_FOLDER, "city_data", "$user_id", "$(user_data[:city_name])_walked.jld2")
    city_data = load(city_data_path)
    city_data_map = city_data["no_graph_map"]
    city_walked_parts = load(city_walked_path)["walked_parts"]
    
    walked_district_kms = EverySingleStreet.get_district_kms(city_data_map, collect(values(city_walked_parts.ways)))
    district_kms = EverySingleStreet.get_district_kms(city_data_map)

    result = Vector{Dict{Symbol, Any}}()
    for district in keys(district_kms)
        if !haskey(walked_district_kms, district)
            push!(result, Dict(:name => district, :kms => district_kms[district], :walked_kms => 0.0, :perc => 0.0))
            continue 
        end
        push!(result, Dict(:name => district, :kms => district_kms[district], :walked_kms => walked_district_kms[district], :perc => 100 * (walked_district_kms[district] / district_kms[district])))
    end
    result = sort(result, by=(d->d[:perc]), rev=true)
    return result
end

function get_district_tags(user_id)
    district_stats = get_district_statistics(user_id)
    district_tags = Dict{Symbol, Vector{Symbol}}()
    for district in district_stats
        perc_rounded = round(Int, district[:perc])
        district_tags[district[:name]] = [Symbol("district_$(perc_rounded)")]
    end
    return district_tags
end

function regenerate_overlay(user_id)
    user_data = readjson(joinpath(DATA_FOLDER, "user_data", "$user_id.json"))
    run_regenerate_overlay(user_id, user_data[:city_name])
end

function add_activity(user_id, activity_id, force_update=false)
    access_token = get_access_token(user_id)
    activity_data = get_activity_data(access_token, activity_id)
    start_time = activity_data[:start_date]
    is_new_activity = download_activity(user_id, access_token, activity_id, start_time)
    if !is_new_activity && !force_update
        @info "The activity was already parsed at an earlier stage"
        return
    end
    
    activity_path = joinpath(DATA_FOLDER, "activities", "$user_id", "$activity_id.json")
    user_data = readjson(joinpath(DATA_FOLDER, "user_data", "$user_id.json"))
    city_data_path = joinpath(DATA_FOLDER, "city_data", "$user_id", "$(user_data[:city_name]).jld2")
    city_walked_path = joinpath(DATA_FOLDER, "city_data", "$user_id", "$(user_data[:city_name])_walked.jld2")
    city_data = load(city_data_path)
    city_data_map = city_data["no_graph_map"]
    city_walked_parts = load(city_walked_path)["walked_parts"]
    statistics_before = calculate_statistics(city_data_map, city_walked_parts)
    data = EverySingleStreet.map_matching(activity_path, city_data_map.ways, city_walked_parts, "tmp_local_map.json")
    @info "Finished map map_matching"
    statistics_after = calculate_statistics(city_data_map, data.walked_parts)
    rm("tmp_local_map.json")

    walked_xml_path = joinpath(DATA_FOLDER, "city_data", "$user_id", "$(user_data[:city_name])_walked.xml")
    district_tags = get_district_tags(user_id)
    EverySingleStreet.create_xml(city_data_map.nodes, data.walked_parts, walked_xml_path; districts=city_data_map.districts, district_tags)
    @info "Finished creating xml"

    run_regenerate_overlay(user_id, user_data[:city_name])

    walked_road_kms_str = @sprintf "Walked road kms: %.2f km" data.this_walked_road_km
    added_kms_str = @sprintf "Added road kms: %.2f km" data.added_kms
    desc = "$walked_road_kms_str\n$added_kms_str"
    for (key, value) in compare_statistics(statistics_before, statistics_after)
        desc = "$desc\n$key $value"
    end

    prepend_activity_description(access_token, activity_data, desc)
    save(city_walked_path, Dict("walked_parts" => data.walked_parts))
end

function run_regenerate_overlay(user_id, city_name)
    if !haskey(ENV, "ESSALY_URL") 
        @warn "No essaly url is given" 
        return
    end
    essaly_url = ENV["ESSALY_URL"]
    url = "$(essaly_url)/api/regenerateOverlay"
    params = Dict(
        "osmosisReadXml"  => joinpath(DATA_FOLDER, "city_data", "$user_id", "$(city_name)_walked.xml"),
        "tilemakerConfig" => joinpath(DATA_FOLDER, "tilemaker", "config.json"),
    )
    @show params
    raw_response = HTTP.request("POST", url,
             ["Content-Type" => "application/x-www-form-urlencoded"],
             HTTP.URIs.escapeuri(params))
             json_response = JSON3.read(String(raw_response.body))
    if raw_response.status != 200
        @warn "Status code for run_regenerate_overlay: $(raw_response.status)"
    end
    if !json_response["metadata"]["success"]
        @show response
    end
end