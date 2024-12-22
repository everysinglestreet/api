function readjson(fpath)
    json_string = read(fpath, String)
    return copy(JSON3.read(json_string))
end

function vector_pair_to_dict(vec::Vector{Pair{K, V}}) where {K, V}
    d = Dict{K, V}()
    for (k,v) in vec
        d[k] = v
    end
    return d
end

function wait_rate_limit(header)
    res_header = vector_pair_to_dict(header)
    haskey(res_header, "x-readratelimit-limit") || return
    haskey(res_header, "x-readratelimit-usage") || return
    ratelimit_15 = parse(Int, split(res_header["x-readratelimit-limit"], ",")[1])
    rateusage_15 = parse(Int, split(res_header["x-readratelimit-usage"], ",")[1])
    diff = ratelimit_15 - rateusage_15
    wait_start_diff = 10
    if diff > wait_start_diff
        return 
    end
    sleep_min = 0
    if diff < 0
        sleep_min = 15
    else
        sleep_min = (wait_start_diff-diff)+1
    end
    @warn "Avoiding reaching rate limit. Wait for $sleep_min minutes. Current rate usage $rateusage_15 out of $ratelimit_15."
    sleep(sleep_min*60)
end