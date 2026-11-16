// Captured from vLLM (AEON-7/Gemma-4-26B-A4B-it-Uncensored-NVFP4) on 2026-11-16, byte for byte except that the
// reasoning stream is cut after its fifth delta.
enum CapturedResponses {
    static let text = #"""
event: response.created
data: {"response":{"id":"resp_9cb1cec31b644d32","created_at":1794834583,"incomplete_details":null,"instructions":null,"metadata":null,"model":"AEON-7/Gemma-4-26B-A4B-it-Uncensored-NVFP4","object":"response","output":[],"parallel_tool_calls":true,"temperature":1.0,"tool_choice":"none","tools":[],"top_p":0.95,"background":false,"max_output_tokens":262075,"max_tool_calls":null,"previous_response_id":null,"prompt":null,"reasoning":{"context":null,"effort":"none","generate_summary":null,"mode":null,"summary":null},"service_tier":"auto","status":"in_progress","text":null,"top_logprobs":null,"truncation":"disabled","usage":null,"user":null,"presence_penalty":0.0,"frequency_penalty":0.0,"kv_transfer_params":null,"ec_transfer_params":null,"input_messages":null,"output_messages":null},"sequence_number":0,"type":"response.created"}

event: response.in_progress
data: {"response":{"id":"resp_9cb1cec31b644d32","created_at":1794834583,"incomplete_details":null,"instructions":null,"metadata":null,"model":"AEON-7/Gemma-4-26B-A4B-it-Uncensored-NVFP4","object":"response","output":[],"parallel_tool_calls":true,"temperature":1.0,"tool_choice":"none","tools":[],"top_p":0.95,"background":false,"max_output_tokens":262075,"max_tool_calls":null,"previous_response_id":null,"prompt":null,"reasoning":{"context":null,"effort":"none","generate_summary":null,"mode":null,"summary":null},"service_tier":"auto","status":"in_progress","text":null,"top_logprobs":null,"truncation":"disabled","usage":null,"user":null,"presence_penalty":0.0,"frequency_penalty":0.0,"kv_transfer_params":null,"ec_transfer_params":null,"input_messages":null,"output_messages":null},"sequence_number":1,"type":"response.in_progress"}

event: response.output_item.added
data: {"item":{"id":"a5418725d0535791","content":[],"role":"assistant","status":"in_progress","type":"message","phase":null},"output_index":0,"sequence_number":2,"type":"response.output_item.added"}

event: response.content_part.added
data: {"content_index":0,"item_id":"a5418725d0535791","output_index":0,"part":{"annotations":[],"text":"","type":"output_text","logprobs":[]},"sequence_number":3,"type":"response.content_part.added"}

event: response.output_text.delta
data: {"content_index":0,"delta":"Hi","item_id":"a5418725d0535791","logprobs":[],"output_index":0,"sequence_number":4,"type":"response.output_text.delta"}

event: response.output_text.delta
data: {"content_index":0,"delta":" there","item_id":"a5418725d0535791","logprobs":[],"output_index":0,"sequence_number":5,"type":"response.output_text.delta"}

event: response.output_text.delta
data: {"content_index":0,"delta":",","item_id":"a5418725d0535791","logprobs":[],"output_index":0,"sequence_number":6,"type":"response.output_text.delta"}

event: response.output_text.delta
data: {"content_index":0,"delta":" friend","item_id":"a5418725d0535791","logprobs":[],"output_index":0,"sequence_number":7,"type":"response.output_text.delta"}

event: response.output_text.delta
data: {"content_index":0,"delta":"!","item_id":"a5418725d0535791","logprobs":[],"output_index":0,"sequence_number":8,"type":"response.output_text.delta"}

event: response.output_text.done
data: {"content_index":0,"item_id":"a5418725d0535791","logprobs":[],"output_index":0,"sequence_number":9,"text":"Hi there, friend!","type":"response.output_text.done"}

event: response.content_part.done
data: {"content_index":0,"item_id":"a5418725d0535791","output_index":0,"part":{"annotations":[],"text":"Hi there, friend!","type":"output_text","logprobs":null},"sequence_number":10,"type":"response.content_part.done"}

event: response.output_item.done
data: {"item":{"id":"a5418725d0535791","content":[{"annotations":[],"text":"Hi there, friend!","type":"output_text","logprobs":null}],"role":"assistant","status":"completed","type":"message","phase":null,"summary":[]},"output_index":0,"sequence_number":11,"type":"response.output_item.done"}

event: response.completed
data: {"response":{"id":"resp_9cb1cec31b644d32","created_at":1794834583,"incomplete_details":null,"instructions":null,"metadata":null,"model":"AEON-7/Gemma-4-26B-A4B-it-Uncensored-NVFP4","object":"response","output":[{"id":"msg_a6faf303a28a91d7","content":[{"annotations":[],"text":"Hi there, friend!","type":"output_text","logprobs":null}],"role":"assistant","status":"completed","type":"message","phase":null}],"parallel_tool_calls":true,"temperature":1.0,"tool_choice":"none","tools":[],"top_p":0.95,"background":false,"max_output_tokens":262075,"max_tool_calls":null,"previous_response_id":null,"prompt":null,"reasoning":{"context":null,"effort":"none","generate_summary":null,"mode":null,"summary":null},"service_tier":"auto","status":"completed","text":null,"top_logprobs":null,"truncation":"disabled","usage":{"input_tokens":39,"input_tokens_details":{"cached_tokens":0,"input_tokens_per_turn":[],"cached_tokens_per_turn":[]},"output_tokens":6,"output_tokens_details":{"reasoning_tokens":0,"tool_output_tokens":0,"output_tokens_per_turn":[],"tool_output_tokens_per_turn":[]},"total_tokens":45},"user":null,"presence_penalty":0.0,"frequency_penalty":0.0,"kv_transfer_params":null,"ec_transfer_params":null,"input_messages":null,"output_messages":null},"sequence_number":12,"type":"response.completed"}

"""#

    static let tool = #"""
event: response.created
data: {"response":{"id":"resp_b984fe8e4c163333","created_at":1794834569,"incomplete_details":null,"instructions":null,"metadata":null,"model":"AEON-7/Gemma-4-26B-A4B-it-Uncensored-NVFP4","object":"response","output":[],"parallel_tool_calls":true,"temperature":1.0,"tool_choice":"auto","tools":[{"name":"get_weather","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]},"strict":null,"type":"function","allowed_callers":null,"async":null,"defer_loading":null,"description":"Weather for a city","output_schema":null}],"top_p":0.95,"background":false,"max_output_tokens":262044,"max_tool_calls":null,"previous_response_id":null,"prompt":null,"reasoning":null,"service_tier":"auto","status":"in_progress","text":null,"top_logprobs":null,"truncation":"disabled","usage":null,"user":null,"presence_penalty":0.0,"frequency_penalty":0.0,"kv_transfer_params":null,"ec_transfer_params":null,"input_messages":null,"output_messages":null},"sequence_number":0,"type":"response.created"}

event: response.in_progress
data: {"response":{"id":"resp_b984fe8e4c163333","created_at":1794834569,"incomplete_details":null,"instructions":null,"metadata":null,"model":"AEON-7/Gemma-4-26B-A4B-it-Uncensored-NVFP4","object":"response","output":[],"parallel_tool_calls":true,"temperature":1.0,"tool_choice":"auto","tools":[{"name":"get_weather","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]},"strict":null,"type":"function","allowed_callers":null,"async":null,"defer_loading":null,"description":"Weather for a city","output_schema":null}],"top_p":0.95,"background":false,"max_output_tokens":262044,"max_tool_calls":null,"previous_response_id":null,"prompt":null,"reasoning":null,"service_tier":"auto","status":"in_progress","text":null,"top_logprobs":null,"truncation":"disabled","usage":null,"user":null,"presence_penalty":0.0,"frequency_penalty":0.0,"kv_transfer_params":null,"ec_transfer_params":null,"input_messages":null,"output_messages":null},"sequence_number":1,"type":"response.in_progress"}

event: response.output_item.added
data: {"item":{"arguments":"","call_id":"call_86c03f762b3db7e5","name":"get_weather","type":"function_call","id":"8e323c97ade86367","async":null,"caller":null,"namespace":null,"status":"in_progress"},"output_index":0,"sequence_number":2,"type":"response.output_item.added"}

event: response.function_call_arguments.delta
data: {"delta":"{\"city\": \"","item_id":"8e323c97ade86367","output_index":0,"sequence_number":3,"type":"response.function_call_arguments.delta"}

event: response.function_call_arguments.delta
data: {"delta":"Paris","item_id":"8e323c97ade86367","output_index":0,"sequence_number":4,"type":"response.function_call_arguments.delta"}

event: response.function_call_arguments.delta
data: {"delta":"\"}","item_id":"8e323c97ade86367","output_index":0,"sequence_number":5,"type":"response.function_call_arguments.delta"}

event: response.function_call_arguments.done
data: {"arguments":"{\"city\": \"Paris\"}","item_id":"8e323c97ade86367","output_index":0,"sequence_number":6,"type":"response.function_call_arguments.done","name":"get_weather"}

event: response.output_item.done
data: {"item":{"arguments":"{\"city\": \"Paris\"}","call_id":"call_86c03f762b3db7e5","name":"get_weather","type":"function_call","id":"8e323c97ade86367","async":null,"caller":null,"namespace":null,"status":"completed"},"output_index":0,"sequence_number":7,"type":"response.output_item.done"}

event: response.completed
data: {"response":{"id":"resp_b984fe8e4c163333","created_at":1794834569,"incomplete_details":null,"instructions":null,"metadata":null,"model":"AEON-7/Gemma-4-26B-A4B-it-Uncensored-NVFP4","object":"response","output":[{"arguments":"{\"city\": \"Paris\"}","call_id":"chatcmpl-tool-89b46b0213293dfa","name":"get_weather","type":"function_call","id":"fc_91784623bf21e19d","async":null,"caller":null,"namespace":null,"status":"completed"}],"parallel_tool_calls":true,"temperature":1.0,"tool_choice":"auto","tools":[{"name":"get_weather","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]},"strict":null,"type":"function","allowed_callers":null,"async":null,"defer_loading":null,"description":"Weather for a city","output_schema":null}],"top_p":0.95,"background":false,"max_output_tokens":262044,"max_tool_calls":null,"previous_response_id":null,"prompt":null,"reasoning":null,"service_tier":"auto","status":"completed","text":null,"top_logprobs":null,"truncation":"disabled","usage":{"input_tokens":70,"input_tokens_details":{"cached_tokens":0,"input_tokens_per_turn":[],"cached_tokens_per_turn":[]},"output_tokens":15,"output_tokens_details":{"reasoning_tokens":0,"tool_output_tokens":0,"output_tokens_per_turn":[],"tool_output_tokens_per_turn":[]},"total_tokens":85},"user":null,"presence_penalty":0.0,"frequency_penalty":0.0,"kv_transfer_params":null,"ec_transfer_params":null,"input_messages":null,"output_messages":null},"sequence_number":8,"type":"response.completed"}

"""#

    static let reasoning = #"""
event: response.created
data: {"response":{"id":"resp_894ffd31aaa567a3","created_at":1794834479,"incomplete_details":null,"instructions":null,"metadata":null,"model":"AEON-7/Gemma-4-26B-A4B-it-Uncensored-NVFP4","object":"response","output":[],"parallel_tool_calls":true,"temperature":1.0,"tool_choice":"none","tools":[],"top_p":0.95,"background":false,"max_output_tokens":262078,"max_tool_calls":null,"previous_response_id":null,"prompt":null,"reasoning":{"context":null,"effort":"low","generate_summary":null,"mode":null,"summary":null},"service_tier":"auto","status":"in_progress","text":null,"top_logprobs":null,"truncation":"disabled","usage":null,"user":null,"presence_penalty":0.0,"frequency_penalty":0.0,"kv_transfer_params":null,"ec_transfer_params":null,"input_messages":null,"output_messages":null},"sequence_number":0,"type":"response.created"}

event: response.in_progress
data: {"response":{"id":"resp_894ffd31aaa567a3","created_at":1794834479,"incomplete_details":null,"instructions":null,"metadata":null,"model":"AEON-7/Gemma-4-26B-A4B-it-Uncensored-NVFP4","object":"response","output":[],"parallel_tool_calls":true,"temperature":1.0,"tool_choice":"none","tools":[],"top_p":0.95,"background":false,"max_output_tokens":262078,"max_tool_calls":null,"previous_response_id":null,"prompt":null,"reasoning":{"context":null,"effort":"low","generate_summary":null,"mode":null,"summary":null},"service_tier":"auto","status":"in_progress","text":null,"top_logprobs":null,"truncation":"disabled","usage":null,"user":null,"presence_penalty":0.0,"frequency_penalty":0.0,"kv_transfer_params":null,"ec_transfer_params":null,"input_messages":null,"output_messages":null},"sequence_number":1,"type":"response.in_progress"}

event: response.output_item.added
data: {"item":{"id":"9000f380140dff4d","summary":[],"type":"reasoning","content":null,"encrypted_content":null,"status":"in_progress"},"output_index":0,"sequence_number":2,"type":"response.output_item.added"}

event: response.reasoning_part.added
data: {"content_index":0,"item_id":"9000f380140dff4d","output_index":0,"part":{"text":"","type":"reasoning_text"},"sequence_number":3,"type":"response.reasoning_part.added"}

event: response.reasoning_text.delta
data: {"content_index":0,"delta":"*","item_id":"9000f380140dff4d","output_index":0,"sequence_number":4,"type":"response.reasoning_text.delta"}

event: response.reasoning_text.delta
data: {"content_index":0,"delta":"   Instruction","item_id":"9000f380140dff4d","output_index":0,"sequence_number":5,"type":"response.reasoning_text.delta"}

event: response.reasoning_text.delta
data: {"content_index":0,"delta":":","item_id":"9000f380140dff4d","output_index":0,"sequence_number":6,"type":"response.reasoning_text.delta"}

event: response.reasoning_text.delta
data: {"content_index":0,"delta":" \"","item_id":"9000f380140dff4d","output_index":0,"sequence_number":7,"type":"response.reasoning_text.delta"}

event: response.reasoning_text.delta
data: {"content_index":0,"delta":"Say","item_id":"9000f380140dff4d","output_index":0,"sequence_number":8,"type":"response.reasoning_text.delta"}

"""#
}
