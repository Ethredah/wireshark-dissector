
-- Dissector package
-- This package attaches the dissector, parsing and display behaviour to the protocol. Unlike other packages this
-- modifies previously created objects.

-- Package header
local master = diffusion or {}
if master.dissector ~= nil then
	return master.dissector
end

-- Import from other packages
local RD, FD, WSMD = diffusion.utilities.RD, diffusion.utilities.FD, diffusion.utilities.WSMD

local f_src_host = diffusion.utilities.f_src_host
local f_dst_host = diffusion.utilities.f_dst_host
local f_src_port = diffusion.utilities.f_src_port
local f_tcp_stream  = diffusion.utilities.f_tcp_stream
local f_http_response_code = diffusion.utilities.f_http_response_code
local f_http_connection = diffusion.utilities.f_http_connection
local f_http_upgrade = diffusion.utilities.f_http_upgrade
local f_http_uri = diffusion.utilities.f_http_uri
local f_ws_b_payload = diffusion.utilities.f_ws_b_payload
local f_ws_t_payload = diffusion.utilities.f_ws_t_payload
local ws_payload_length = diffusion.utilities.ws_payload_length
local f_frame_number = diffusion.utilities.f_frame_number
local index = diffusion.utilities.index

local tcpConnections = diffusion.info.tcpConnections
local DescriptionsTable = diffusion.info.DescriptionsTable
local topicInfoTable = diffusion.info.topicInfoTable

local nameByID = diffusion.messages.nameByID
local messageTypeLookup = diffusion.messages.messageTypeLookup

local dptProto = diffusion.proto.dptProto

local DIFFUSION_MAGIC_NUMBER = diffusion.const.DIFFUSION_MAGIC_NUMBER
local TOPIC_VALUE_MESSAGE_TYPE = diffusion.const.TOPIC_VALUE_MESSAGE_TYPE
local TOPIC_DELTA_MESSAGE_TYPE = diffusion.const.TOPIC_DELTA_MESSAGE_TYPE

local parseAsV4ServiceMessage = diffusion.parseService.parseAsV4ServiceMessage
local parseAsV59ServiceMessage = diffusion.parseService.parseAsV59ServiceMessage
local parseConnectionRequest = diffusion.parse.parseConnectionRequest
local parseConnectionResponse = diffusion.parse.parseConnectionResponse
local parseWSConnectionRequest = diffusion.parse.parseWSConnectionRequest
local parseWSConnectionResponse = diffusion.parse.parseWSConnectionResponse
local decodeMessageType = diffusion.parse.decodeMessageType
local decodeMessageEncoding = diffusion.parse.decodeMessageEncoding
local varint = diffusion.parseCommon.varint

local addClientConnectionInformation = diffusion.displayConnection.addClientConnectionInformation
local addHeaderInformation = diffusion.display.addHeaderInformation
local addBody = diffusion.display.addBody
local addConnectionHandshake = diffusion.displayConnection.addConnectionHandshake
local addServiceInformation = diffusion.displayService.addServiceInformation
local addDescription = diffusion.display.addDescription

local v5 = diffusion.v5
local SERVICE_TOPIC = v5.SERVICE_TOPIC

local LENGTH_LEN = 4 -- LLLL
local HEADER_LEN = 2 + LENGTH_LEN -- LLLLTE, usually

local tcp_dissector_table = DissectorTable.get("tcp.port")
local http_dissector = tcp_dissector_table:get_dissector(80)

local DPT_TYPE = "DPT_TYPE"
local DPWS_TYPE = "DPWS_TYPE"

-- Dissect the connection negotiation messages
local function dissectConnection( tvb, pinfo )
	-- Is this a client or server packet?
	local tcpStream, host, port = f_tcp_stream(), f_src_host(), f_src_port()

	local client = tcpConnections[tcpStream].client
	local server = tcpConnections[tcpStream].server
	local isClient = client:matches( host, port )

	if isClient then
		return parseConnectionRequest( tvb, client )
	else
		return parseConnectionResponse( tvb, client )
	end
end

local function tryDissectWSConnection( tvb, pinfo )
	local uri = f_http_uri()
	if uri ~= nil then
		if uri:string():startsWith("/diffusion") then
			local tcpStream = f_tcp_stream()
			return parseWSConnectionRequest( tvb, tcpConnections[tcpStream].client )
		end
	end

	return nil
end

local function tryDissectWSConnectionResponse( tvb, pinfo, tree )
	-- Get the payload of the websocket response, assumes 1 byte per character
	local _, websocketResponseStart = tvb:range():string():find("\r\n\r\n");
	local websocketResponseRange = tvb:range( websocketResponseStart + 2 );

	local tcpStream = f_tcp_stream()
	local client = tcpConnections[tcpStream].client
	return parseWSConnectionResponse( websocketResponseRange, client )
end

local function processContent( pinfo, contentRange, messageTree, messageType, msgDetails, descriptions )
	if messageType.id == TOPIC_VALUE_MESSAGE_TYPE or messageType.id == TOPIC_DELTA_MESSAGE_TYPE then
		local idRange = contentRange( 0, 4 )
		messageTree:add( dptProto.fields.topicId, idRange )
		local tcpStream = f_tcp_stream()
		local topicPath = topicInfoTable:getTopicPath( tcpStream, idRange:int() )
		if topicPath ~= nil then
			local pathNode = messageTree:add( dptProto.fields.topicPath, idRange, topicPath )
			pathNode:set_generated()
			messageType.topicDescription = topicPath
		end

		if contentRange:len() > 4 then
			local payload = contentRange( 4 )
			messageTree:add( dptProto.fields.content, payload, string.format( "%d bytes", payload:len() ) )
		else
			messageTree:add( dptProto.fields.content, contentRange( 0, 0 ), string.format( "0 bytes" ) )
		end

		addDescription( pinfo, messageType, nil, nil, descriptions )
		return
	end

	local headerInfo, serviceInfo, records
	-- The headers & body -- find the 1st RD in the content
	local headerBreak = index( contentRange:bytes(), RD )
	if headerBreak >= 0 then
		local headerRange = contentRange:range( 0, headerBreak )

		-- Pass the header-node to the MessageType for further processing
		headerInfo = messageType:markupHeaders( headerRange )

		if headerBreak + 1 <= (contentRange:len() -1) then
			-- Only markup up the body if there is one (there needn't be)
			local bodyRange = contentRange:range( headerBreak + 1 )

			if headerInfo.topic ~= nil and headerInfo.topic.topic ~= nil and headerInfo.topic.topic.string == SERVICE_TOPIC then
				serviceInfo = parseAsV4ServiceMessage( bodyRange )
			end

			records = messageType:markupBody( msgDetails, bodyRange )
			if serviceInfo ~= nil then
				addServiceInformation( messageTree, serviceInfo, records )
			end
		end

		if serviceInfo == nil then
			local contentNode = messageTree:add( dptProto.fields.content, contentRange, string.format( "%d bytes", contentRange:len() ) )
			local headerNode = contentNode:add( dptProto.fields.headers, headerRange, string.format( "%d bytes", headerBreak ) )
			addHeaderInformation( headerNode, headerInfo )
			if records ~= nil then
				addBody( contentNode , records, headerInfo )
			end
		end
	end

	-- Set the Info column of the tabular display -- NB: this must be called last
	addDescription( pinfo, messageType, headerInfo, serviceInfo, descriptions )
end

-- Process an individual DPT message
local function processMessage( tvb, pinfo, tree, offset, descriptions )
	local msgDetails = {}

	local tcpStream = f_tcp_stream() -- get the artificial 'tcp stream' number
	local conn = tcpConnections[tcpStream]
	local client
	if conn ~= nil then
		client = conn.client
	end

	-- Assert there is enough to parse even the LLLL segment
	if offset + LENGTH_LEN >  tvb:len() then
		-- Signal Wireshark that more bytes are needed
		pinfo.desegment_len = DESEGMENT_ONE_MORE_SEGMENT -- Using LENGTH_LEN gets us into trouble
		return -1
	end

	-- Get the size word
	local messageStart = offset
	local msgSizeRange = tvb( offset, LENGTH_LEN )
	msgDetails.msgSize = msgSizeRange:uint()
	offset = offset +4

	-- Assert there is enough to parse - having read LLLL
	local messageContentLength = ( msgDetails.msgSize - LENGTH_LEN )
	if offset + messageContentLength > tvb:len() then
		-- Signal Wireshark that more bytes are needed
		pinfo.desegment_len = DESEGMENT_ONE_MORE_SEGMENT
		return -1
	end

	-- Get the type byte
	local msgTypeRange = tvb( offset, 1 )
	msgDetails.msgType = msgTypeRange:uint()
	offset = offset +1

	-- Get the encoding byte
	local msgEncodingRange = tvb( offset, 1 )
	msgDetails.msgEncoding = msgEncodingRange:uint()
	offset = offset +1

	-- Add to the GUI the size-header, type-header & encoding-header
	local messageRange = tvb( messageStart, msgDetails.msgSize )
	local messageTree = tree:add( dptProto, messageRange )

	messageTree:add( dptProto.fields.sizeHdr, msgSizeRange )
	local typeNode = messageTree:add( dptProto.fields.typeHdr, msgTypeRange )
	local messageTypeName = nameByID( msgDetails.msgType )
	typeNode:append_text( " = " .. messageTypeName )
	messageTree:add( dptProto.fields.encodingHdr, msgEncodingRange )

	addClientConnectionInformation( messageTree, tvb, client, f_src_host(), f_src_port() )

	local contentSize, contentRange
	if msgDetails.msgType == 0x1c or msgDetails.msgType == 0x1d then
		-- Close and abort do not have content
		contentSize = 0
		contentRange = tvb( 0, 0 )
	else
		-- The content range
		contentSize = msgDetails.msgSize - HEADER_LEN
		contentRange = tvb( offset, contentSize )
	end

	offset = offset + contentSize
	local messageType = messageTypeLookup(msgDetails.msgType)

	if messageType.id == v5.MODE_REQUEST or messageType.id == v5.MODE_RESPONSE or messageType.id == v5.MODE_ERROR then
		local serviceInfo = parseAsV59ServiceMessage( msgTypeRange, contentRange )
		addServiceInformation( messageTree, serviceInfo, client )
		-- Set the Info column of the tabular display -- NB: this must be called last
		addDescription( pinfo, messageType, {}, serviceInfo, descriptions )
	else
		processContent( pinfo, contentRange, messageTree, messageType, msgDetails, descriptions )
	end

	return offset
end

local function processWSMessage( tvb, pinfo, tree, descriptions )
	local msgDetails = {}

	msgDetails.msgSize = tvb:len()
	-- Get the type by
	local msgTypeRange = tvb( 0, 1 )
	msgDetails.msgType = decodeMessageType( msgTypeRange:uint() )
	msgDetails.msgEncoding = decodeMessageEncoding( msgTypeRange:uint() )
	local messageType = messageTypeLookup(msgDetails.msgType)

	-- Add to the GUI the size-header, type-header & encoding-header
	local messageRange = tvb( start, msgDetails.msgSize )
	local messageTree = tree:add( dptProto, messageRange )

	messageTree:add( dptProto.fields.sizeHdr, messageRange, msgDetails.msgSize )
	local typeNode = messageTree:add( dptProto.fields.typeHdr, msgTypeRange, msgDetails.msgType )
	messageTree:add( dptProto.fields.encodingHdr, msgTypeRange, msgDetails.msgEncoding )
	local messageTypeName = nameByID( msgDetails.msgType )
	typeNode:append_text( " = " .. messageTypeName )

	local tcpStream = f_tcp_stream() -- get the artificial 'tcp stream' number
	local conn = tcpConnections[tcpStream]
	local client
	if conn ~= nil then
		client = conn.client
	end
	addClientConnectionInformation( messageTree, tvb, client, f_src_host(), f_src_port() )

	local contentSize, contentRange
	if msgDetails.msgType == 0x1c or msgDetails.msgType == 0x1d then
		-- Close and abort do not have content
		contentSize = 0
		contentRange = tvb( 0, 0 )
	else
		-- The content range
		contentSize = msgDetails.msgSize - 1
		contentRange = tvb( 1, contentSize )
	end

	if messageType.id == v5.MODE_REQUEST or messageType.id == v5.MODE_RESPONSE or messageType.id == v5.MODE_ERROR then
		local serviceInfo = parseAsV59ServiceMessage( msgTypeRange, contentRange )
		addServiceInformation( messageTree, serviceInfo, client )
		-- Set the Info column of the tabular display -- NB: this must be called last
		addDescription( pinfo, messageType, {}, serviceInfo, descriptions )
	else
		processContent( pinfo, contentRange, messageTree, messageType, msgDetails, descriptions )
	end
end

function dptProto.init()
	info( "dptProto.init()" )
end

local function call_http_dissector( tvb, pinfo, tree )
	-- Ensure that the HTTP dissector can reassemble TCP packets
	local can_desegment = pinfo.can_desegment
	pinfo.can_desegment = 2

	http_dissector:call( tvb, pinfo, tree )

	pinfo.can_desegment = can_desegment
end

local function protectedDissector( tvb, pinfo, tree )
	-- Ignore cut off packets
	if tvb:len() ~= tvb:reported_len() then
		info( string.format( "Skipping truncated frame %d", f_frame_number() ) )
		return 0
	end

	local streamNumber = f_tcp_stream()

	-- Is this a connection negotiation?
	-- Dissect connection and mark stream as DPT
	local firstByte = tvb( 0, 1 ):uint()
	if firstByte == DIFFUSION_MAGIC_NUMBER then
		tcpConnections[streamNumber].type = DPT_TYPE

		-- Set the tabular display
		pinfo.cols.protocol = dptProto.name

		-- process & skip over it, if it is.
		local handshake = dissectConnection( tvb, pinfo )
		addConnectionHandshake( tree, tvb(), pinfo, handshake )
		return {}
	end

	call_http_dissector( tvb, pinfo, tree )

	local connection = f_http_connection()
	local upgrade = f_http_upgrade()

	-- Detect if it is a websocket connection
	if connection ~= nil and
			upgrade ~=nil and
			string.lower( connection ) == "upgrade" and
			string.lower( upgrade ) == "websocket" then

		local handshake = tryDissectWSConnection( tvb, pinfo )
		if handshake ~= nil then
			pinfo.cols.protocol = "DP-WS"
			tcpConnections[streamNumber].type = DPWS_TYPE
			addConnectionHandshake( tree, tvb(), pinfo, handshake )
			return {}
		end
	end

	if tcpConnections[streamNumber].type == DPT_TYPE then
		local descriptions = DescriptionsTable:new()
		-- Set the tabular display
		pinfo.cols.protocol = dptProto.name

		local offset = 0
		repeat
			-- -1 indicates incomplete read
			 offset = processMessage( tvb, pinfo, tree, offset, descriptions )
		until ( offset == -1 or offset >= tvb:len() )

		-- Set description
		pinfo.cols.info:clear_fence()
		pinfo.cols.info = descriptions:summarise()
		pinfo.cols.info:fence()

	elseif tcpConnections[streamNumber].type == DPWS_TYPE then

		local descriptions = DescriptionsTable:new()
		pinfo.cols.protocol = "DP-WS"
		local response = f_http_response_code()
		if response == 101 then
			local handshake = tryDissectWSConnectionResponse( tvb, pinfo, tree)
			if handshake ~= nil then
				addConnectionHandshake( tree, tvb(), pinfo, handshake )
			end
		else
			local payloads
			local client = tcpConnections[f_tcp_stream()].client
			if client.protoVersion > 4 then
				payloads = f_ws_b_payload()
			else
				payloads = f_ws_t_payload()
			end
			for i, p in ipairs( payloads ) do
				-- WS contains 1 Diffusion message per WS frame
				processWSMessage( p, pinfo, tree, descriptions )
			end

			-- Set description
			pinfo.cols.info:clear_fence()
			pinfo.cols.info = descriptions:summarise()
			pinfo.cols.info:fence()
		end
	end
end

function dptProto.dissector( tvb, pinfo, tree )
	local status, result = pcall(function () protectedDissector( tvb, pinfo, tree ) end)
	if status then
		return result
	else
		info( string.format( "Frame %d, error %s", f_frame_number(), result ) )
		return 0
	end
end

-- Package footer
master.dissector = {}
diffusion = master
return master.dissector
