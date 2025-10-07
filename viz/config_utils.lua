local ConfigUtils = {}

function ConfigUtils.streamColor(streams, name)
	local stream = streams and streams[name]
	return stream and stream.color or nil
end

function ConfigUtils.primaryJoinConfig(data)
	if data and data.joins and data.joins[1] then
		return data.joins[1]
	end
	return (data and data.join) or {}
end

function ConfigUtils.resolveObservable(observables, name, fallback)
	if name and observables and observables[name] then
		return observables[name]
	end
	if fallback then
		return observables and observables[fallback] or nil
	end
	return nil
end

function ConfigUtils.minFieldValue(list, field)
	if type(list) ~= "table" or type(field) ~= "string" or field == "" then
		return nil
	end
	local minValue = nil
	for _, item in ipairs(list) do
		local value = item and item[field]
		if type(value) == "number" then
			if not minValue or value < minValue then
				minValue = value
			end
		end
	end
	return minValue
end

return ConfigUtils
