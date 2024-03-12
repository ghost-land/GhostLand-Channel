require 'scripts/helpers/httphelper.lua'
require 'scripts/utils/ErrorConverter.lua'

-- Set it to true for builtin catalog
useDebugCatalog = true

CatalogHandler = class(HttpHelper)

function CatalogHandler:start()
	print('CatalogHandler:start()')
	self.i_error = 1
	self.serviceToken = nil
	self:httpInit()

	-- conflicted with a method name
	self.b_endOfService = false
	self.serviceUrl1 = "https://lightning-dev.mobiclip.com/front/service"				-- NERD (used for debug)
 	self.serviceUrlCustom = "https://raw.githubusercontent.com/ghost-land/GhostLand-Channel/main/server%20side/front/catalog.json"                          -- your catalog URL goes here
	self.serviceUrl = self.serviceUrlCustom
	
	-- Video player settings
	self.downloadMaxAttempts = 1

	-- Language
	self.lang, self.country = Localization_getLocale()

	-- Dev secret
	self.secret = ""
	print("Looking for secret...")
	local secretFileName = "sdmc:/devSecret.txt"
	if FileUtils_fileExists(secretFileName) == true then

		-- Common data
		local secretFile = FileUtils_openFile(secretFileName)
		local secretData = jsonDecode(FileUtils_readFile(secretFile))
		self.secret = secretData.devSecret

		-- Parameters
		if secretData.country ~= nil then
			self.country = secretData.country
			print("Found secret data : country = " .. self.country)
		end
		if secretData.serviceUrl ~= nil then
			self.serviceUrl = secretData.serviceUrl
			print("Found secret data : serviceUrl = " .. self.serviceUrl)
		end
		if secretData.date ~= nil then
			self.date = secretData.date
			print("Found secret data : date = " .. self.date)
		end

		FileUtils_closeFile(secretFile)
	end
end


--------------------------------------------------------------------------------
-- Script interface
--------------------------------------------------------------------------------

function CatalogHandler:getRoot()
	--Before anything else, removing the current catalog to clean up
	local root = {}
	local channels = {}
	local episodes = {}
	self.i_error = 'MSG_CATALOG_DL_FAILED'; --The download has failed unless proven otherwise. (To be less dependent on the current state of the CatalogHandler).

	local result = ""
	local errorCount = 0
	if useDebugCatalog == false then

		-- Request
		local requestHeaders = {}
		local requestActions = {{
			getNode = {id = "root", type = "root"}
		}}

		local serviceToken = self:getServiceToken()

		--if not serviceToken then
		--	self.i_error = 'MSG_NNID_REQUIRED';
		--else
			local httpHeaders = {
				['Content-Type'] = "vnd.nerd.nppmessage+json",
				['X-Service-Token'] = serviceToken
			}

			-- Try sending up to downloadMaxAttempts times
			while self.i_error ~= 0 and errorCount < self.downloadMaxAttempts do
				print('CatalogHandler:getRoot - Attempting download. errorCount: ' .. errorCount)
				print('self.serviceUrl: ' .. tostring(self.serviceUrl))
				result, self.i_error = self:httpGet(self.serviceUrl, httpHeaders)
				print('JSON length: ' .. tostring(string.len(tostring(result))))
				--print(result)
				errorCount = errorCount + 1
			end
		--end

	else
		result = debugCatalog
		self.i_error = 0
	end

	-- Parse the result
	if self.i_error == 0 then
		--print(tostring(result))
		self:dispatchMOPPMessage(result, root, channels, episodes)		-- will parse JSON and set channels and episodes arrays
		local catalog = self:setupData(root, channels, episodes)
		return catalog
	else

		-- Is this a network connectivity issue ?
		print('CatalogHandler:getRoot - Failed to download, checking netork status')
		local networkStatus = ReedPlayer_getNetworkStatusCode()
		if networkStatus > 0 then
			Application_displayNetworkErrorFromCode(networkStatus)
			self.i_error = 'MSG_CATALOG_DL_FAILED'
		end

		if self.i_error == 'MSG_NNID_REQUIRED' then
			self.i_error = 'MSG_NNID_REQUIRED'
			LightningPlayer.menu.catalogTable:printStatus(__('MSG_NNID_REQUIRED'))
		else
			self.i_error = 'MSG_CATALOG_DL_FAILED'
			LightningPlayer.menu.catalogTable:printStatus(__('MSG_CATALOG_DL_FAILED'))
		end
		--LightningPlayer.menu.catalogTable:showReloadButton()
		print(
			'CatalogHandler:getRoot\nFailed for ' .. self.serviceUrl ..
			'\n(error ' .. string.format('%q', self.i_error) .. ')')
		return {}
	end
end

--- Setup data
-- This is really ugly performance-wise (O(episodes * channels))
-- We need to store episodes in a {ID -> episodeData} array, sorted by ID, and use find
-- Input: channels, episodes, root
-- Output: catalog
function CatalogHandler:setupData(root, channels, episodes)
	-- Add channels from root to catalog
	local catalog = {}
	if root.children ~= nil and #root.children > 0 then
		-- attach episodes to channels
		for i = 1, #channels do
			for j = 1, #channels[i].children do
				local id = channels[i].children[j].id
				for k = 1, #episodes do
					for nodeName, nodeVal in pairs(episodes[k]) do
						if nodeName == 'id' and nodeVal == id then
							channels[i].children[j] = episodes[k]
						end
					end
				end
			end
		end

		-- attach channels to catalog
		for i = 1, #root.children do
			local id = root.children[i].id
			for j = 1, #channels do
				if id == channels[j].id then
					table.insert(catalog, channels[j])
				end
			end
		end
		print('Catalog is build. #' .. tostring(#catalog))
	elseif (self.i_error == 0) then
		self.i_error = 'MSG_COUNTRY_NOT_AVAILABLE'
		LightningPlayer.menu.catalogTable:printStatus(__('MSG_COUNTRY_NOT_AVAILABLE'))
		--LightningPlayer.menu.catalogTable:showReloadButton()
	else
		-- otherwise the error message is already taken care of in CatalogHandler:error()
		print('CatalogHandler:setupData() error ' .. tostring(self.i_error) .. ' should have been displayed')
	end

	-- Cleanup
	print('Got ' .. #episodes .. ' episodes in ' .. #channels .. ' channels, root: ' .. #root)
	return catalog
end

function CatalogHandler:incrementViewCount(episode)
	print('CatalogHandler:incrementViewCount(' .. episode .. ')')

	local serviceToken = self:getServiceToken()

	if serviceToken then
		local requestHeaders = {}
		local requestActions = {{
			incViewCount = {id = episode}
		}}
		local httpHeaders = {
			['Content-type'] = "vnd.nerd.nppmessage+json",
			['X-Service-Token'] = serviceToken
		}

		-- Server communication
		postData = self:encodeMOPPMessage(requestHeaders, requestActions)
		local result, error = self:httpPost(self.serviceUrl, postData, httpHeaders)
		self.i_error = error
		if self.i_error == 0 then
			self:dispatchMOPPMessage(result, root, channels, episodes)
		end
	end
end

function CatalogHandler:isEndOfService()
	return self.b_endOfService
end

--------------------------------------------------------------------------------
-- Internal helpers
--------------------------------------------------------------------------------

function CatalogHandler:getServiceToken()
	self.serviceToken = "thisistheservicetoken" --don't need to be changed
	return self.serviceToken --fuck nnid check
end

--------------------------------------------------------------------------------
-- MOPP protocol
--------------------------------------------------------------------------------

function CatalogHandler:encodeMOPPMessage(headers, actions)
	-- Protocol headers
	local msg = {
		head = {
			protocolVersion = "1.0",
			apiVersion = "1.0",
			device = {
				language = self.lang,
				country = self.country
			}
		},
		body = actions
	}

	-- Secret mode
	if self.secret ~= nil and string.len(self.secret) > 0 then
		msg.head['devSecret'] = self.secret
		msg.head['forceCountry'] = self.country
		msg.head['forceDate'] = self.date
	end

	-- User headers
	for k, v in pairs(headers) do
		msg.head[k] = v
	end
	return jsonEncode(msg)
end

function CatalogHandler:dispatchMOPPMessage(moppMessageData, root, channels, episodes)
	local msg = jsonDecode(moppMessageData)
	--var_dump(msg)

	-- Dispatch actions
	if msg ~= nil then
		for i = 1, #msg.body do
			local actionName, actionData = next(msg.body[i])
			--print('MOPP action: ' .. tostring(actionName))
			if self[actionName] then
				self[actionName](self, msg.headers, actionData, root, channels, episodes)
			elseif self.onUnknownAction then
				self:onUnknownAction(msg.headers, actionName, actionData)
			end
		end
	else
		print(debug.getinfo(1, "n").name .. 'msg is nil. JSON parsing failed');
		print('moppMessageData.len: ' .. string.len(moppMessageData));
		print('"' .. moppMessageData .. '"\n')
		self.i_error = 'MSG_CATALOG_DL_FAILED'
		LightningPlayer.menu.catalogTable:printStatus("090-2920\n\n" .. __('MSG_CATALOG_DL_FAILED'))
		--LightningPlayer.menu.catalogTable:showReloadButton()
	end
end


--------------------------------------------------------------------------------
-- MOPP actions
--------------------------------------------------------------------------------

function CatalogHandler:endOfService(headers, data)
	self.b_endOfService = false
end

function CatalogHandler:setNode(headers, data, root, channels, episodes)
	local nodeType = data['type']
	--print('setNode type: ' .. tostring(nodeType))
	if nodeType == 'channel' then
		table.insert(channels, data)
	elseif nodeType == 'episode' then
		table.insert(episodes, data)
	elseif nodeType == 'root' then
		for key, val in pairs(data) do
			root[key] = val
		end
	else
		print('Unknown data type : ' .. nodeType)
	end
end

function CatalogHandler:setProfiles(headers, data)
	print('"setProfiles" action handler...')
end

function CatalogHandler:incViewCountResponse(headers, data)
	if data.success ~= true then
		print('incrementViewCount failed !')
	else
		print('incrementViewCount succeeded')
	end
end

function CatalogHandler:onUnknownAction(headers, name, data)
	print(string.format('Unhandled action: "%s"', name))
	var_dump(data, 'data')

	keys = {}
	for key,value in pairs(self) do
		table.insert(keys, key)
	end
	var_dump(keys, 'CatalogHandler methods')
end

function CatalogHandler:error(headers, data)
	print('errorMessage: ' .. tostring(data.errorMessage))
	var_dump(data, 'data')

	self.i_error = 'MSG_CATALOG_DL_FAILED'

	if not LightningPlayer.menu.networkErrorNotifier:isNotifying() then -- If there is a network error pop-up opened already, we suppress the error.
		LightningPlayer.menu:closePopups() -- If there are other pop-ups, we close them to avoid overlap.
		local message = __('MSG_CATALOG_DL_FAILED')

		if data ~= nil and data['errorCode'] ~= nil then
			local errorCode = data['errorCode']
			if errorCode >= 2910 and errorCode <= 2919 then --errors related to service token, invalidate the current one
				self.serviceToken = nil
			elseif errorCode < 1000 then --http style error code, to convert
				errorCode = convertToLightningErrorCode(errorCode)
			end

			if errorCode == 2912 then
				message = __('MSG_OUTDATED_1TU_SERVICE_TOKEN')
			end

			message = "090-" .. errorCode .. "\n\n" .. message --crude display of Lightning specific errors
		end


		LightningPlayer.menu:getPlaybackObject():closeVideo() --since we are planning on reloading the catalog, we already stop the possibly playing video (instead of having it rerunning while there is an error message.
		local listener = {notificationDismissed  = 	function()
														if LightningPlayer.menu.currentPage == LightningPlayer.menu.splashPage then
															LightningPlayer.menu.isFirstFrame = true
														else
															if LightningPlayer.menu.currentPage ~= LightningPlayer.menu.catalogPage then
																LightningPlayer.menu:goToCatalog()
															end
															print("Simulating click on reload button for automatic retry.")
															LightningPlayer.menu.catalogTable:clickReloadButton()
														end
													end}
		LightningPlayer.menu.networkErrorNotifier:notify(message, LightningPlayer.menu.errorSound, listener)
	end
end

require 'scripts/content/debugcatalog.lua'
