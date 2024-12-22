using Dates
import DotEnv
using EverySingleStreet
using OrderedCollections
using Printf
using JLD2
using JSON3
using Oxygen
using HTTP
using Base.Threads

DotEnv.config()
const VERIFY_TOKEN = ENV["VERIFY_TOKEN"]
const DATA_FOLDER = ENV["DATA_FOLDER"]

include("strava_api.jl")
include("utils.jl")

@get "/subscribe" function(req::HTTP.Request)
    params = queryparams(req)
    verify_token = get(params, "hub.verify_token", "")
    if verify_token != VERIFY_TOKEN
        return html(""; status=401)
    end
    return Dict{String,String}("hub.challenge" => get(params,"hub.challenge", "not available"))
end

@post "/subscribe" function(req::HTTP.Request)
    data = json(req)
    if data[:aspect_type] == "create" && data[:object_type] == "activity"
        @spawn add_activity(data[:owner_id], data[:object_id])
    end
    return "EVENT_RECEIVED"
end

@post "/add_city" function(req::HTTP.Request)
    data = json(req)
    add_city(data[:owner_id], data[:long_name], data[:short_name])
    return "CITY_ADDED"
end

@post "/full_update" function(req::HTTP.Request)
    data = json(req)
    if haskey(data, :city_name)
        full_update(data[:owner_id], data[:city_name])
    else
        full_update(data[:owner_id])
    end
    return "EVENT_RECEIVED"
end


@post "/regenerateOverlay" function(req::HTTP.Request)
    data = json(req)
    if haskey(data, :city_name)
        run_regenerate_overlay(data[:owner_id], data[:city_name])
    else
        regenerate_overlay(data[:owner_id])
    end
    return Dict(:success => true)
end

@get "/districts" function(req::HTTP.Request)
    data = json(req)
    return get_district_statistics(data[:owner_id], data[:city_name])
end

@get "/statistics" function(req::HTTP.Request)
    data = json(req)
    return get_statistics(data[:owner_id])
end

@get "/activity_statistics" function(req::HTTP.Request)
    data = json(req)
    return get_activity_statistics(data[:owner_id])
end

@get "/last_image" function(req::HTTP.Request)
    params = queryparams(req)
    fname = get_last_image_path(params)
    file(fname)
end


serve(host="0.0.0.0", port=8000)