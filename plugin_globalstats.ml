open Common
open Xml


let stats_sum serverlist result out =
   let totals = ref 0 in
   let onlines = ref 0 in
   let servers = ref 0 in
   let sin = open_in serverlist in
   let rec each_server server =
      let proc x o =
	 (match safe_get_attr_s x "type" with
	    | "result" ->
		 let stats = get_subels ~path:["query"] ~tag:"stat" x in
		 let data = List.map (fun z ->
					 get_attr_s z "name",		 
					 try 
					    int_of_string (get_attr_s z "value")
					 with Not_found -> 0 ) stats in
		    totals := !totals + List.assoc "users/total" data;
		    onlines := !onlines + List.assoc "users/online" data;
		    servers := !servers + 1
	    | _ -> ());
	 try
	    let server = input_line sin in
	       each_server server
	 with End_of_file ->
	    let sout = open_out result in
	       output_string sout ("Total " ^ string_of_int !totals ^ "\n");
	       output_string sout ("Online " ^ string_of_int !onlines ^ "\n");
	       output_string sout ("servers " ^ string_of_int !servers ^ "\n");
	       close_in sin;
	       close_out sout
      in
      let id = Hooks.new_id () in
	 Hooks.register_handle (Hooks.Id (id, proc));
	 out (Xmlelement 
		 ("iq", ["to", server; "type", "get"; "id", id],
		  [Xmlelement 
		      ("query", ["xmlns", 
				 "http://jabber.org/protocol/stats"],
		       [Xmlelement ("stat", ["name", "users/online"], []);
			Xmlelement ("stat", ["name", "users/total"], [])
		       ])]))
   in
   let server = input_line sin in
      each_server server

let cmd_stats text xml out =
   let server = text in
   let proc x o =
      match safe_get_attr_s x "type" with
	 | "result" ->
	      let stats = get_subels ~path:["query"] ~tag:"stat" x in
	      let data = List.map (fun z ->
				      get_attr_s z "name",		 
				      try 
					 get_attr_s z "value"
				      with Not_found -> "unknown" ) stats in
		 o (make_msg xml 
		       (Printf.sprintf "\nUsers Total: %s\nUsers Online: %s"
			   (List.assoc "users/total" data)
			   (List.assoc "users/online" data)))
	 | "error" ->
	      o (make_msg xml 
		    (Lang.get_msg ~xml "plugin_globalstats_stats_error" []))
	 | _ -> ()
   in
   let id = Hooks.new_id () in
      Hooks.register_handle (Hooks.Id (id, proc));
      out (Xmlelement 
	      ("iq", ["to", server; "type", "get"; "id", id],
	       [Xmlelement ("query", ["xmlns", 
				      "http://jabber.org/protocol/stats"],
			    [Xmlelement ("stat", ["name", "users/online"], []);
			     Xmlelement ("stat", ["name", "users/total"], [])
			    ])]))

let uptime text xml out =
   if text = "" then 
      out (make_msg xml 
	      (Lang.get_msg ~xml "plugin_globalstats_uptime_invalid_syntax" []))
   else
      let proc x o =
	 match get_attr_s x "type" with
	    | "result" ->
		 let seconds = get_attr_s x ~path:["query"] "seconds" in
		 let last = seconds_to_text seconds in
		    o (make_msg xml 
			  (Printf.sprintf "%s uptime is %s" text last))
	    | "error" ->
		 o (make_msg xml (try get_error_semantic x with Not_found ->
				     Lang.get_msg ~xml 
					"plugin_globalstats_uptime_error" []))
	    | _ -> ()
      in
      let id = Hooks.new_id () in
	 Hooks.register_handle (Hooks.Id (id, proc));
	 out (Iq.iq_query "jabber:iq:last" text id)

let _ =
   if Xml.mem_xml Config.config ["sulci"; "plugins"; "globalstats"] "store" [] 
   then
      begin
	 let serverlist = get_attr_s Config.config 
	    ~path:["plugins"; "globalstats"; "store"] "serverlist" in
	 let result = get_attr_s Config.config 
	    ~path:["plugins"; "globalstats"; "store"] "result" in
	 let interval = float_of_string 
	    (get_attr_s Config.config
		~path:["plugins"; "globalstats"; "store"] "interval") in
	 let start_stats out =
	    let rec cycle out () =
	       stats_sum serverlist result out;
	       Timer.add_timer interval (cycle out);
	    in
	       cycle out ()

	 in
	    Hooks.register_handle (Hooks.OnStart start_stats)
      end;
   Hooks.register_handle (Hooks.Command ("stats", cmd_stats));
   Hooks.register_handle (Hooks.Command ("uptime", uptime))