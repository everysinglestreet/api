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

function add_activity(user_id, activity_id, force_update=false)
    access_token = get_access_token(user_id)
    activity_data = get_activity_data(access_token, activity_id)
    start_time = activity_data[:start_date]
    is_new_activity = download_activity(user_id, access_token, activity_id, start_time)
    if !is_new_activity && !force_update
        return
    end
    
    activity_path = joinpath(DATA_FOLDER, "activities", "$user_id", "$activity_id.json")
    user_data = readjson(joinpath(DATA_FOLDER, "user_data", "$user_id.json"))
    city_data_path = joinpath(DATA_FOLDER, "city_data", "$user_id", "$(user_data[:city_name]).jld2")
    city_data = load(city_data_path)
    data = EverySingleStreet.map_matching(activity_path, city_data["ways"], city_data["walked_parts"], "tmp_local_map.json")
    rm("tmp_local_map.json")

    added_kms_str = @sprintf "Added road kms: %.2f km" data.added_kms
    save(city_data_path, Dict("nodes" => city_data["nodes"], "ways" => city_data["ways"], "walked_parts" => data.walked_parts))

    walked_xml_path = joinpath(DATA_FOLDER, "city_data", "$user_id", "$(user_data[:city_name])_walked.xml")
    EverySingleStreet.create_xml(city_data["nodes"], data.walked_parts, walked_xml_path)

    run_osmosis_conversion(user_id, user_data[:city_name])
    run_tilemaker_conversion(user_id, user_data[:city_name])
    run_restart_overlay()

    prepend_activity_description(access_token, activity_data, added_kms_str)
end

function run_osmosis_conversion(user_id, city_name)
    essaly_url = ENV["ESSALY_URL"]
    url = "$(essaly_url)/api/executeOsmosis"
    params = Dict(
        "input"  => joinpath(DATA_FOLDER, "data", "city_data", "$user_id", "$(city_name)_walked.xml"),
        "output" => joinpath(DATA_FOLDER, "data", "city_data", "$user_id", "$(city_name)_walked.osm.pbf"),
    )
    raw_response = HTTP.request("POST", url,
             ["Content-Type" => "application/x-www-form-urlencoded"],
             HTTP.URIs.escapeuri(params))
    json_response = JSON3.read(String(raw_response.body))
    if !json_response["metadata"]["success"]
        @show response
    end
end

function run_tilemaker_conversion(user_id, city_name)
    essaly_url = ENV["ESSALY_URL"]
    url = "$(essaly_url)/api/executeTilemaker"
    params = Dict(
        "input"  => joinpath(DATA_FOLDER, "data", "city_data", "$user_id", "$(city_name)_walked.osm.pbf"),
        "output" => joinpath(DATA_FOLDER, "data", "city_data", "$user_id", "walked.mbtiles"),
        "config" => joinpath(DATA_FOLDER, "data", "tilemaker", "config.json"),
    )
    raw_response = HTTP.request("POST", url,
             ["Content-Type" => "application/x-www-form-urlencoded"],
             HTTP.URIs.escapeuri(params))
             json_response = JSON3.read(String(raw_response.body))
    if !json_response["metadata"]["success"]
        @show response
    end
end

function run_restart_overlay()
    essaly_url = ENV["ESSALY_URL"]
    url = "$(essaly_url)/api/restartOverlay"
    raw_response = HTTP.request("POST", url)
             json_response = JSON3.read(String(raw_response.body))
    if !json_response["metadata"]["success"]
        @show response
    end
end