(*                                                                          *)
(* (c) 2004, Anastasia Gornostaeva. <ermine@ermine.pp.ru>                   *)
(*                                                                          *)

open Common
open Xml
open Xmpp
open Hooks
open Unix
open Pcre

type muc_event = | MUC_join of string 
		 | MUC_leave of string * string
		 | MUC_change_nick of string * string * string
		 | MUC_kick of string * string
		 | MUC_ban of string * string
		 | MUC_presence
		 | MUC_topic of string
		 | MUC_message
		 | MUC_ignore

let basedir = trim (Xml.get_cdata Config.config ~path:["muc"; "chatlogs"])

module LogMap = Map.Make(Id)
let logmap = ref LogMap.empty

let open_log room =
   let tm = localtime (time ()) in
   let year = tm.tm_year + 1900 in
   let month = tm.tm_mon + 1 in
   let day = tm.tm_mday in

   let p1 = Filename.concat basedir room in
   let () = if not (Sys.file_exists p1) then mkdir p1 0o755 in
   let p2 = Printf.sprintf "%s/%i" p1 year in
   let () = if not (Sys.file_exists p2) then mkdir p2 0o755 in
   let p3 = Printf.sprintf "%s/%0.2i" p2 month in
   let () = if not (Sys.file_exists p3) then mkdir p3 0o755 in
   let file = Printf.sprintf "%s/%0.2i.html" p3 day in
      if not (Sys.file_exists file) then
	 let out_log = open_out_gen [Open_creat; Open_append] 0o644 file in
	    output_string out_log 
	       (Printf.sprintf 
		   "<html><head>
<meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\" />
<title>%s</title></head><body><h1>%s</h1><h2>%s</h2>\n"
		   room room room);
	    flush out_log;
	    out_log
      else
	 open_out_gen [Open_append] 0o644 file

let get_next_noun () =
   let curr_time = gettimeofday () in
   let curr_tm = localtime curr_time in
   let noun, _ = mktime {curr_tm with 
			    tm_sec = 0; tm_min = 0; tm_hour = 0;
			    tm_mday = curr_tm.tm_mday + 1} in
      noun -. curr_time

let rec rotate_logs () =
print_endline "rotating logs";
   logmap := LogMap.mapi (fun room lf ->
			     output_string lf "</body>\n</html>";
			     flush lf;
			     close_out lf;
			     open_log room) !logmap;
   
   Timer.add_timer (get_next_noun ()) rotate_logs

let () = Timer.add_timer (get_next_noun ()) rotate_logs

let get_logfile room =
   try 
      LogMap.find room !logmap 
   with Not_found -> 
      let out_log = open_log room in
	 logmap := LogMap.add room out_log !logmap;
	 out_log

let rex = regexp "((https?|ftp)://[^ ]+|(www|ftp)[a-z0-9.-]*\\.[a-z]{2,4}[^ ]*)"

let html_url text =
   try
      substitute ~rex 
	 ~subst:(fun url ->
		    if pmatch ~pat:".+//:" url then
		       Printf.sprintf "<a href='%s'>%s</a>" url url
		    else if pmatch ~pat:"^www" url then
		       Printf.sprintf "<a href='http://%s'>%s</a>" url url
		    else if pmatch ~pat:"^ftp" url then
		       Printf.sprintf "<a href='ftp://%s'>%s</a>" url url
		    else 
		       Printf.sprintf "<a href='%s'>%s</a>" url url
		)
	 text
   with Not_found -> text

let to_log room text =
   let out_log = get_logfile room in
   let curtime = Strftime.strftime ~tm:(localtime (time ())) "%H:%M" in
      output_string out_log 
	 (Printf.sprintf 
	     "[%s] %s<br>\n"
	     curtime text);
      flush out_log

let make_message nick body =
   let text =
      Pcre.substitute_substrings ~pat:"\n( *)"
	 ~subst:(fun s ->
		    try
		       let sub = Pcre.get_substring s 1 in
		       let len = String.length sub in
		       let buf = Buffer.create (len * 6) in
			  for i = 1 to len do
			     Buffer.add_string buf "&nbsp;"
			  done;
			  "<br>\n" ^ Buffer.contents buf
		    with _ -> "<br>"
		) body
   in
      Printf.sprintf "&lt;%s&gt; %s" nick (html_url text)

let make_subject subject =
   html_url subject

let make_me nick body =
   let action = string_after body 4 in
      Printf.sprintf "* %s %s" nick  (html_url action)
	 
let log_message xml =
   if safe_get_attr_s xml "type" = "groupchat" then
      let from = get_attr_s xml "from" in
      let room = get_bare_jid from in
	 if mem_xml xml ["message"] "subject" [] then
	    let subject = try get_cdata xml ~path:["body"] with _ -> 
	       get_cdata xml ~path:["subject"] in
	       to_log room (make_subject subject)
	 else
	    let body = try get_cdata xml ~path:["body"] with _ -> "" in
	       if body <> "" then
		  let text = 
		     let nick = get_resource from in
			if pmatch ~pat:"/me" body then
			   make_me nick body
			else
			   make_message nick body
		  in
		     to_log room text

let log_presence room event lang =
   let text = match event with
      | MUC_join user ->
	   Lang.get_msg ~lang "muc_log_join" [user]
      | MUC_leave (user, reason) ->
	   if reason = "" then
	      Lang.get_msg ~lang "muc_log_leave" [user]
	   else
	      Lang.get_msg ~lang "muc_log_leave_reason" [user; reason]
      | MUC_kick (user, reason) ->
	   if reason = "" then
	      Lang.get_msg ~lang "muc_log_kick" [user]
	   else
	      Lang.get_msg ~lang "muc_log_kick_reason" [user; reason]
      | MUC_ban (user, reason) ->
	   if reason = "" then
	      Lang.get_msg ~lang "muc_log_ban" [user]
	   else
	      Lang.get_msg ~lang "muc_log_ban_reason" [user; reason]
      | MUC_change_nick (newnick, user, orignick) ->
	   Lang.get_msg ~lang "muc_log_change_nick" [user; newnick]
      | _ -> ""
   in
      if text <> "" then
	 to_log room ("-- " ^ text)


let process_presence xml out =
   let from = get_attr_s xml "from" in
   let user = get_resource from in
   let room = get_bare_jid from in
   let room_env = GroupchatMap.find room !groupchats in
   let x = List.find (function 
			 | Xmlelement ("x", attrs, _) ->
			      if (try List.assoc "xmlns" attrs with _ -> "")=
				 "http://jabber.org/protocol/muc#user" 
			      then true else false
			 | _ -> false
		     ) (Xml.get_subels xml) in
   let event = match safe_get_attr_s xml "type"  with
      | "" -> 
	   let status = try get_cdata xml ~path:["status"] with _ -> "" in
	   let show = try get_cdata xml ~path:["show"] with _ -> "available" in
	      if not (Nicks.mem user room_env.nicks) then begin
		 let item = { jid = (try get_attr_s x ~path:["item"] "jid"
				     with _ -> "");
			      role = (try get_attr_s x ~path:["item"] "role" 
				      with _ -> "");
			      affiliation = (try get_attr_s x 
						~path:["item"] "affiliation"
					     with _ -> "");
			      status = status;
			      show = show;
			      orig_nick = user
			    } in
		    groupchats := GroupchatMap.add room 
		       {room_env with nicks = Nicks.add user item
			     room_env.nicks} !groupchats;
		 MUC_join user
	      end
	      else
		 let item = Nicks.find user room_env.nicks in
		    groupchats := GroupchatMap.add room 
		       {room_env with 
			   nicks = Nicks.add user 
			     {item with status = status; show = show;} 
			     room_env.nicks} !groupchats;
		    MUC_ignore
      | "unavailable" -> 
	   (match safe_get_attr_s x ~path:["status"] "code" with
	       | "303" -> (* /nick *)
		    let newnick = 
		       get_attr_s xml ~path:["x"; "item"] "nick" in
		    let item = Nicks.find user room_env.nicks in
		       groupchats := GroupchatMap.add room
			  {room_env with nicks = 
				Nicks.add newnick item
				   (Nicks.remove user room_env.nicks)} 
			  !groupchats;
		       MUC_change_nick (newnick, user, item.orig_nick)
	       | "307" -> (* /kick *)
		    let reason = 
		       try get_cdata ~path:["reason"] x with _ -> "" in
		       groupchats := GroupchatMap.add room
			  {room_env with nicks =
				Nicks.remove user room_env.nicks} !groupchats;
		       MUC_kick (user, reason)
	       | "301" -> (* /ban *)
		    let reason = 
		       try get_cdata ~path:["reason"] x with _ -> "" in
		       groupchats := GroupchatMap.add room
			  {room_env with nicks =
				Nicks.remove user room_env.nicks} !groupchats;
		       MUC_ban (user, reason)
	       | "321" (* non-member *)
	       | _ ->
		    let reason = 
		       try get_cdata ~path:["status"] xml with _ -> "" in
		       groupchats := GroupchatMap.add room
			  {room_env with nicks =
				Nicks.remove user room_env.nicks} !groupchats;
		       MUC_leave (user, reason)
	   )
      | _ -> MUC_ignore
   in 
      log_presence room event room_env.lang

let process_message xml out = 
   ()

let dispatch xml out =
   if get_tagname xml = "presence" then
      process_presence xml out
   else 
      if get_tagname xml = "message" &&
	 not (mem_xml xml ["message"] "x" ["xmlns", "jabber:x:delay"]) then
	    begin
	       log_message xml;
	       process_message xml out
	    end

let join_room nick room =
   make_presence 
      ~subels:
      [Xmlelement ("x", ["xmlns", "http://jabber.org/protocol/muc"], [])]
      (room ^ "/" ^ nick)

let kick id room nick reason =
   Xmlelement ("iq", ["to", room; "type", "set"; "id", id],
	       [Xmlelement ("query", ["xmlns",
				      "http://jabber.org/protocol/muc#admin"],
			    [Xmlelement ("item", ["nick", nick; "role", "none"],
					 [make_simple_cdata "reason" reason]
					)])])

let on_start out =
   GroupchatMap.iter (fun room env ->
			 out (join_room env.mynick room)) !groupchats

let register_room nick room =
   groupchats := GroupchatMap.add room {mynick = nick;
			      nicks = Nicks.empty;
			      lang = "ru"} !groupchats;
   Hooks.register_handle (Hooks.From (room, dispatch))

let _ =
   let default_mynick = 
      trim (Xml.get_cdata Config.config ~path:["jabber"; "user"]) in
   let rconf = 
      try Xml.get_subels ~path:["muc"] ~tag:"room" Config.config with _ -> [] in

      List.iter 
	 (fun r ->
	     let mynick = try Xml.get_attr_s r "nick" with _ -> default_mynick
	     and roomname = Xml.get_attr_s r "jid"
	     and lang = try Xml.get_attr_s r "lang" with _ -> "ru" in
		groupchats:= GroupchatMap.add roomname 
		   {mynick = mynick;
		    nicks = Nicks.empty;
		    lang = lang} !groupchats;
		Hooks.register_handle (Hooks.From (roomname, dispatch))
	 ) rconf;
      Hooks.register_handle (OnStart on_start)
 
