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

    r.status != 200 && @show r.status
    result = JSON3.read(String(r.body))
    return result[:access_token]
end

function get_activity_data(access_token, activity_id)
    url = "https://www.strava.com/api/v3/activities/$activity_id"

    headers = Dict("Authorization" => "Bearer $access_token", "Content-Type" => "application/json")

    r = HTTP.request("GET", url, headers)
    r.status != 200 && @show r.status
    json_result = JSON3.read(String(r.body))
    return json_result
end

function download_activity(user_id, access_token, activity_id, start_time)
    path = joinpath(DATA_FOLDER, "activities", "$user_id", "$activity_id.json")
    isfile(path) && return false

    url = "https://www.strava.com/api/v3/activities/$activity_id/streams?keys=latlng,time"

    headers = Dict("Authorization" => "Bearer $access_token", "Content-Type" => "application/json")
    r = HTTP.request("GET", url, headers)
    r.status != 200 && @show r.status

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

    r.status != 200 && @show r.status
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
        result_dict[Symbol("Total: ")] = @sprintf "> %.0f%%" floor(after_total_perc)
    end
    for (district, perc)  in after.district_percentages
        iszero(perc) && continue
        if !haskey(before.district_percentages, district) || iszero(before.district_percentages[district])
            result_dict[Symbol("$district: ")] = @sprintf "First %.1f%%" perc
        elseif perc ÷ 5 > before.district_percentages[district] ÷ 5
            result_dict[Symbol("$district: ")] = @sprintf "> %.0f%%" perc ÷ 5 * 5
        end
    end
    return result_dict
end

function get_statistics(user_id)
    user_data = readjson(joinpath(DATA_FOLDER, "user_data", "$user_id.json"))
    city_data_path = joinpath(DATA_FOLDER, "city_data", "$user_id", "$(user_data[:city_name]).jld2")
    city_walked_path = joinpath(DATA_FOLDER, "city_data", "$user_id", "$(user_data[:city_name])_walked.jld2")
    city_data = load(city_data_path)
    city_data_map = city_data["no_graph_map"]
    city_walked_parts = load(city_walked_path)["walked_parts"]
    activity_path = joinpath(DATA_FOLDER, "activities", "$user_id")
    walked_road_km = EverySingleStreet.total_length(city_walked_parts; filter_fct=(way)->EverySingleStreet.iswalkable_road(way))/1000
    road_km = EverySingleStreet.total_length(city_data_map; filter_fct=(way)->EverySingleStreet.iswalkable_road(way))/1000
    return (walked_road_km = walked_road_km, road_km = road_km, perc = walked_road_km / road_km * 100, num_activities=length(readdir(activity_path)))
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

function get_district_levels(user_id)
    district_stats = get_district_statistics(user_id)
    district_levels = Dict{Symbol, Int}()
    for district in district_stats
        perc_rounded = round(Int, district[:perc]/10)
        district_levels[district[:name]] = perc_rounded
    end
    return district_levels
end

function regenerate_overlay(user_id)
    user_data = readjson(joinpath(DATA_FOLDER, "user_data", "$user_id.json"))
    run_regenerate_overlay(user_id, user_data[:city_name])
end

function get_all_activities(access_token)
    activities = Any[]

    i = 1
    while i <= 1000
        len_before = length(activities)
        url = "https://www.strava.com/api/v3/athlete/activities?per_page=30&page=$i"

        headers = Dict("Authorization" => "Bearer $access_token", "Content-Type" => "application/json")

        r = HTTP.request("GET", url, headers)
        r.status != 200 && @show r.status
        json_result = JSON3.read(String(r.body))
        for res in json_result
            push!(activities, res)
        end
        if length(activities) == len_before
            break
        end
        i += 1
    end
    
    return reverse(activities)
end

function full_update(user_id)
    access_token = get_access_token(user_id)
    all_activities = get_all_activities(access_token)
    @show length(all_activities)
    user_data = readjson(joinpath(DATA_FOLDER, "user_data", "$user_id.json"))
    walked_before = joinpath(DATA_FOLDER, "city_data", "$user_id", "$(user_data[:city_name])_walked.jld2")
    walked_old = joinpath(DATA_FOLDER, "city_data", "$user_id", "$(user_data[:city_name])_walked_old.jld2")
    time_diff = Dates.unix2datetime(time()) - Dates.unix2datetime(mtime(walked_before))
    if time_diff > Hour(5)
        println("Moved old walked.jld2")
        if isfile(walked_before)
            mv(walked_before, walked_old; force=true)
        end
        walked_parts = EverySingleStreet.WalkedParts(Dict{String, Vector{Int}}(), Dict{Int, EverySingleStreet.WalkedWay}())
        save(walked_before, Dict("walked_parts" => walked_parts))   
    end
    for (i,activity_data) in enumerate(all_activities)
        perc = i/length(all_activities)*100
        @show perc
        shall_regnerate_overlay = i % 10 == 0
        shall_regnerate_overlay |= i == length(all_activities)
        start_time_str = activity_data[:start_date]
        df = dateformat"y-m-d"
        start_time = Date(start_time_str[1:10], df)
        # if year(start_time) < 2024
            add_activity(user_id, access_token, activity_data, >(Hour(5)); update_description=false, shall_regnerate_overlay)
        # else 
            # println("Skipped as not done in 2023 or before")
        # end
    end
end

function save_activity_statistics(user_id, access_token, activity_id, data)
    d = Dict{Symbol, Any}()
    activity_data = get_activity_data(access_token, activity_id)
    d[:strava_data] = activity_data
    d[:added_km] = data.added_kms
    d[:walked_road_km] = data.this_walked_road_km
    path = joinpath(DATA_FOLDER, "statistics", "$user_id", "$activity_id.json")
    mkpath(dirname(path))
    open(path, "w") do io
        JSON3.pretty(io, d)
    end 
end

function get_estimate_eoy(perc, boy=20.128365843493164)
    this_year = perc - boy
    days_so_far =  Dates.dayofyear(Dates.now())
    days_total = Dates.dayofyear(Dates.Date("2024-12-31"))
    return boy + this_year / days_so_far * days_total
end

function add_activity(user_id, access_token, activity_data, force_update=(time_diff)->false; update_description=true, shall_regnerate_overlay=true)
    start_time = activity_data[:start_date]
    activity_id = activity_data[:id]
    is_new_activity = download_activity(user_id, access_token, activity_id, start_time)
    statistics_path = joinpath(DATA_FOLDER, "statistics", "$user_id", "$activity_id.json")
    activity_path_tmp = joinpath(DATA_FOLDER, "activities", "$user_id", "$(activity_id).json")
    time_diff = Dates.unix2datetime(time()) - Dates.unix2datetime(mtime(statistics_path))
    time_since_update = Dates.canonicalize(Dates.CompoundPeriod(time_diff))
    !is_new_activity && println("Time since last update: $time_since_update")
    if !is_new_activity && !force_update(time_diff)
        @info "The activity was already parsed at an earlier stage"
        return
    end
    user_data = readjson(joinpath(DATA_FOLDER, "user_data", "$user_id.json"))
    city_data_path = joinpath(DATA_FOLDER, "city_data", "$user_id", "$(user_data[:city_name]).jld2")
    city_walked_path = joinpath(DATA_FOLDER, "city_data", "$user_id", "$(user_data[:city_name])_walked.jld2")
    city_data = load(city_data_path)
    city_data_map = city_data["no_graph_map"]
    city_walked_parts = load(city_walked_path)["walked_parts"]
    statistics_before = calculate_statistics(city_data_map, city_walked_parts)
    data = EverySingleStreet.map_matching(activity_path_tmp, city_data_map, city_walked_parts, "tmp_local_map.json")
    @info "Finished map map_matching"
    statistics_after = calculate_statistics(city_data_map, data.walked_parts)
    rm("tmp_local_map.json")
    

    walked_xml_path = joinpath(DATA_FOLDER, "city_data", "$user_id", "$(user_data[:city_name])_walked.xml")
    district_levels = get_district_levels(user_id)
    EverySingleStreet.create_xml(city_data_map.nodes, data.walked_parts, walked_xml_path; districts=city_data_map.districts, district_levels)
    @info "Finished creating xml"

    shall_regnerate_overlay && run_regenerate_overlay(user_id, user_data[:city_name])

    walked_road_kms_str = @sprintf "Walked road kms: %.2f km" data.this_walked_road_km
    added_kms_str = @sprintf "Added road kms: %.2f km" data.added_kms
    desc = "$walked_road_kms_str\n$added_kms_str"
    est_eoy = get_estimate_eoy(statistics_after.walked_road_km / statistics_after.road_km * 100)
    est_eoy_str = @sprintf "Est. EOY: %.1f%%" est_eoy
    desc = "$desc\n$est_eoy_str"
    for (key, value) in compare_statistics(statistics_before, statistics_after)
        desc = "$desc\n$key $value"
    end

    update_description && prepend_activity_description(access_token, activity_data, desc)
    save(city_walked_path, Dict("walked_parts" => data.walked_parts))
    save_activity_statistics(user_id, access_token, activity_id, data)
    GC.gc()
end

function add_activity(user_id, activity_id::Int, force_update=(time_diff)->false; update_description=true)
    access_token = get_access_token(user_id)
    activity_data = get_activity_data(access_token, activity_id)
    return add_activity(user_id, access_token, activity_data, force_update; update_description)
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