(*                                                                          *)
(* (c) 2004, 2005 Anastasia Gornostaeva. <ermine@ermine.pp.ru>              *)
(*                                                                          *)

open Common
open Xml
open Xmpp
open Types

let process_presence (from:jid) xml out =
   let room = from.luser, from.lserver in
   let luser = from.lresource in
   let room_env = GroupchatMap.find room !groupchats in
   let x = get_by_xmlns xml ~tag:"x" "http://jabber.org/protocol/muc#user" in
   let type_, status = presence_info xml in
      match type_ with
	 | `Available show -> begin
	      try
		 let item = Nicks.find luser room_env.nicks in
		 let newitem = {item with status = status; show = show } in
		    groupchats := GroupchatMap.add room 
		       {room_env with 
			   nicks = Nicks.add luser newitem
			     room_env.nicks} !groupchats;
		    MUC_presence newitem
	      with Not_found -> 
		 let item = { 
		    jid = (try Some (jid_of_string 
					(get_attr_s x ~path:["item"] "jid"))
			   with _ -> None);
		    role = (try get_attr_s x ~path:["item"] "role" 
			    with _ -> "");
		    affiliation = (try get_attr_s x 
				      ~path:["item"] "affiliation"
				   with _ -> "");
		    status = status;
		    show = show;
		    orig_nick = luser
		 } in
		    groupchats := GroupchatMap.add room 
		       {room_env with nicks = Nicks.add luser item
			     room_env.nicks} !groupchats;
		    MUC_join item
	   end
	 | `Unavailable ->
	      (match safe_get_attr_s x ~path:["status"] "code" with
		  | "303" -> (* /nick *)
		       let newnick = 
			  Stringprep.resourceprep 
			     (get_attr_s xml ~path:["x"; "item"] "nick") in
		       let item = Nicks.find luser room_env.nicks in
			  groupchats := GroupchatMap.add room
			     {room_env with nicks = 
				   Nicks.add newnick item
				      (Nicks.remove luser 
					  room_env.nicks)} 
			     !groupchats;
			  MUC_change_nick (newnick, item)
		  | "307" -> (* /kick *)
		       let item = Nicks.find luser
			  (GroupchatMap.find room !groupchats).nicks in
		       let reason =
			  try get_cdata ~path:["item";"reason"] x with _ -> 
			     "" in
			  groupchats := GroupchatMap.add room
			     {room_env with nicks =
				   Nicks.remove luser 
				      room_env.nicks} !groupchats;
			  MUC_kick (reason, item)
		  | "301" -> (* /ban *)
		       let item = Nicks.find luser 
			  (GroupchatMap.find room !groupchats).nicks in
		       let reason = 
			  try get_cdata ~path:["item";"reason"] x with _ -> 
			     "" in
			  groupchats := GroupchatMap.add room
			     {room_env with nicks =
				   Nicks.remove luser 
				      room_env.nicks} !groupchats;
			  MUC_ban (reason, item)
		  (* | "321" (* non-member *) *)
		  | other ->
		       if other = "" &&
			  luser = (GroupchatMap.find room !groupchats).mynick
		       then
			  groupchats := GroupchatMap.remove room !groupchats;
		       let item = Nicks.find luser 
			  (GroupchatMap.find room !groupchats).nicks in
		       let reason = 
			  try get_cdata ~path:["status"] xml with _ -> "" in
			  groupchats := GroupchatMap.add room
			     {room_env with nicks =
				   Nicks.remove luser 
				      room_env.nicks} !groupchats;
			  MUC_leave (reason, item)
	      )
	 | _ -> MUC_other

let split_nick_body room_env body =
   let rec cycle pos =
      try
	 let colon = String.rindex_from body pos ':' in
	    if String.length body > colon+1 then
	       if body.[colon+1] = ' ' then 
		  let nick = String.sub body 0 colon in
		     if Nicks.mem nick room_env.nicks then
			nick, string_after body (colon+2)
		     else
			cycle (colon-1)
	       else
		  cycle (colon-1)
	    else
	       let nick = String.sub body 0 colon in
		  if Nicks.mem nick room_env.nicks then
		     nick, ""
		  else
		     cycle (colon-1)
      with Not_found ->
	 "", body
   in
      if Nicks.mem body room_env.nicks then
	 body, ""
      else
	 let rn, rt = cycle (String.length body - 1) in
	    if rn = "" then
	       if Nicks.mem rt room_env.nicks then
		  rt, ""
	       else
		  "", rt
	    else
	       rn, rt

let process_message (from:jid) xml out = 
   let room = from.luser, from.lserver in
      if (mem_xml xml ["message"] "x" ["xmlns", "jabber:x:delay"]) then
	 MUC_history
      else
	 try
	    let subject = get_cdata xml ~path:["subject"] in
	       MUC_topic subject
	 with Not_found ->
	    try 
	       let body = get_cdata xml ~path:["body"] in
	       let msg_type = 
		  try match get_attr_s xml "type" with
		     | "groupchat" -> `Groupchat
		     | "chat" -> `Chat
		     | "error" -> `Error
		     | _ -> `Normal
		  with _ -> `Normal in
		  match msg_type with
		     | `Groupchat ->
			  let room_env = GroupchatMap.find room !groupchats in
			  let nick, text = split_nick_body room_env body in
			     MUC_message (msg_type, nick, text)
		     | _ ->
			  MUC_message (msg_type, "", body)
	    with Not_found ->
	       MUC_other

let join_room nick (luser, lserver) =
   make_presence ~to_:(luser ^ "@" ^ lserver ^ "/" ^ nick)
      ~subels:
      [Xmlelement ("x", ["xmlns", "http://jabber.org/protocol/muc"], [])] ()

let leave_room ?reason (luser, lserver) =
   let mynick = (GroupchatMap.find (luser, lserver) !groupchats).mynick in
      make_presence ~to_:(luser ^ "@" ^ lserver ^ "/" ^ mynick) 
	 ~type_:`Unavailable ?status:reason ()

let kick id (room:jid) nick (reason, args) =
   let msg = 
      Lang.get_msg ~lang:(GroupchatMap.find (room.luser, room.lserver) 
			     !groupchats).lang reason args
   in
      Xmlelement ("iq", ["to", room.user ^ "@" ^ room.server; 
			 "type", "set"; "id", id],
		  [Xmlelement ("query", 
			       ["xmlns",
				"http://jabber.org/protocol/muc#admin"],
			       [Xmlelement ("item", ["nick", nick; 
						     "role", "none"],
					    [make_simple_cdata "reason" msg]
					   )])])

let set_topic from subject =
   Xmlelement ("message", ["to", from.user ^ "@" ^ from.server;
			   "type", "groupchat"],
	       [make_simple_cdata "subject" subject])

let register_room ?lang nick (luser, lserver) =
   groupchats := GroupchatMap.add (luser, lserver)
      {
	 mynick = Stringprep.stringprep ~mode:Stringprep.Resourceprep nick;
	 nicks = Nicks.empty;
	 lang = match lang with
	    | None -> Lang.deflang
	    | Some l -> l } !groupchats
      
let _ =
   let default_mynick = 
      trim (Xml.get_cdata Config.config ~path:["jabber"; "user"]) in
   let rconf = 
      try Xml.get_subels ~path:["muc"] ~tag:"room" Config.config with _ -> [] in

      List.iter 
	 (fun r ->
	     let mynick = try 
		Stringprep.stringprep ~mode:Stringprep.Resourceprep
		   (Xml.get_attr_s r "nick") with Not_found -> default_mynick
	     and jid_s = Xml.get_attr_s r "jid"
	     and lang = try Xml.get_attr_s r "lang" with _ -> "ru" in
	     let jid = jid_of_string jid_s in
		register_room ~lang mynick (jid.luser, jid.lserver)
	 ) rconf
 
