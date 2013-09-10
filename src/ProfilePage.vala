/*  This file is part of corebird, a Gtk+ linux Twitter client.
 *  Copyright (C) 2013 Timm Bäder
 *
 *  corebird is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  corebird is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with corebird.  If not, see <http://www.gnu.org/licenses/>.
 */

using Gtk;

[GtkTemplate (ui = "/org/baedert/corebird/ui/profile-page.ui")]
class ProfilePage : ScrollWidget, IPage {
  private static const int PAGE_TWEETS     = 0;
  private static const int PAGE_FOLLOWING  = 1;
  private static const int PAGE_FOLLOWERS  = 2;

  public int unread_count {
    get{return 0;}
    set{}
  }
  private int id;
  public unowned MainWindow main_window { get; set; }
  public unowned Account account { get; set; }

  [GtkChild]
  private ImageBox banner_box;
  [GtkChild]
  private Gtk.Image avatar_image;
  [GtkChild]
  private Label name_label;
  [GtkChild]
  private Label description_label;
  [GtkChild]
  private Label url_label;
  [GtkChild]
  private Label location_label;
  [GtkChild]
  private TextButton tweets_button;
  [GtkChild]
  private TextButton following_button;
  [GtkChild]
  private TextButton followers_button;
  [GtkChild]
  private Button follow_button;
  [GtkChild]
  private Gtk.Stack bottom_stack;
  private bool following;
  private int active_page       = 0;
  private int64 user_id;
  private string screen_name; //TODO: Remove


  public ProfilePage(int id, MainWindow window, Account account){
    this.main_window = window;
    this.id = id;
    this.button_press_event.connect (button_pressed_event_cb);
    tweets_button.clicked.connect(() => {
      switch_page (PAGE_TWEETS);
    });
    following_button.clicked.connect(() => {
      switch_page (PAGE_FOLLOWING);
    });
    followers_button.clicked.connect(() => {
      switch_page (PAGE_FOLLOWERS);
    });
  }

  public void set_user_id(int64 user_id){
    this.user_id = user_id;

    /* Load the profile data now, then - if available - set the cached data */
    load_profile_data.begin(user_id);

    if (user_id  == account.id) {
      follow_button.hide ();
    }

    banner_box.set_background(DATADIR+"/no_banner.png");
    //Load cached data
    string query_string = "SELECT id, screen_name, name, description, tweets,
           following, followers, avatar_name, banner_url,
           url, location, following, is_following, banner_name
           FROM profiles ";
    query_string += @"WHERE id='$user_id';";

    Corebird.db.exec (query_string, (n_cols, vals) => {
      /* If we get inside this block, there is already some data in the
        DB we can use. */
        avatar_image.pixbuf = new Gdk.Pixbuf.from_file (Utils.user_file ("/assets/avatars/"+vals[7]));

      set_data(vals[2], vals[1], vals[9], vals[10], vals[3],
               int.parse (vals[4]), int.parse (vals[5]), int.parse (vals[6]));
      //follow_button.active = bool.parse (vals[12]);
      set_follow_button_state (bool.parse (vals[12]));
      string banner_name = vals[13];
      debug("banner_name: %s", banner_name);

      if (banner_name != null &&
          FileUtils.test(Utils.user_file("assets/banners/"+banner_name), FileTest.EXISTS)){
        debug("Banner exists, set it directly...");
        banner_box.set_background(Utils.user_file(
                      "assets/banners/"+banner_name));
      } else {
        // If the cached banner does somehow not exist, load it again.
        debug("Banner %s does not exist, load it first...", banner_name);
        banner_box.set_background(DATADIR+"/no_banner.png");
      }
      return Sql.STOP;
    });
  }


  private async void load_profile_data(int64 user_id){
    var call = account.proxy.new_call();
    call.set_method("GET");
    call.set_function("1.1/users/show.json");
    call.add_param("user_id", user_id.to_string());
    call.invoke_async.begin(null, (obj, res) => {
      try{
        call.invoke_async.end (res);
      } catch (GLib.Error e){
        warning("Error while ending call: %s", e.message);
        return;
      }
      string back = call.get_payload();
      Json.Parser parser = new Json.Parser();
      try{
        parser.load_from_data(back);
      } catch (GLib.Error e){
        warning ("Error while loading profile data: %s", e.message);
        return;
      }

      var root = parser.get_root().get_object();
      int64 id = root.get_int_member ("id");

      string avatar_url = root.get_string_member("profile_image_url");
      avatar_url = avatar_url.replace("_normal", "_bigger");
      string avatar_name = Utils.get_avatar_name(avatar_url);
      string avatar_on_disk = Utils.user_file("assets/avatars/"+avatar_name);

      if(!FileUtils.test(avatar_on_disk, FileTest.EXISTS)){
        Utils.download_file_async.begin(avatar_url, avatar_on_disk,
          () => { avatar_image.pixbuf = new Gdk.Pixbuf.from_file (avatar_on_disk);
          });
      }else
        avatar_image.pixbuf = new Gdk.Pixbuf.from_file (avatar_on_disk);

      string name        = root.get_string_member("name");
             screen_name = root.get_string_member("screen_name");
      string description = root.get_string_member("description").replace("&", "&amp;");
      int followers      = (int)root.get_int_member("followers_count");
      int following      = (int)root.get_int_member("friends_count");
      int tweets         = (int)root.get_int_member("statuses_count");
      bool is_following  = root.get_boolean_member("following");
      bool has_url       = root.get_object_member("entities").has_member("url");
      string banner_name = get_banner_name(user_id);

      if (root.has_member ("profile_banner_url")) {
        string banner_base_url = root.get_string_member ("profile_banner_url");
        load_profile_banner (banner_base_url, user_id, screen_name);
      }

      string display_url = null;
      if(has_url) {
        var urls_object = root.get_object_member("entities")
          .get_object_member("url").get_array_member("urls").get_element(0)
            .get_object();

        var url = urls_object.get_string_member("expanded_url");
        if (urls_object.has_member ("display_url")) {
          display_url = urls_object.get_string_member("expanded_url");
        } else {
          url = urls_object.get_string_member("url");
          display_url = url;
        }
      }

      string location = null;
      if(root.has_member("location")){
        location     = root.get_string_member("location");
      }

      set_data(name, screen_name, display_url, location, description, tweets,
           following, followers);
 //     follow_button.active = is_following;
      set_follow_button_state (is_following);

      Corebird.db.exec (
          @"INSERT OR REPLACE INTO `profiles`(`id`, `screen_name`, `name`,
             `followers`, `following`, `tweets`, `description`, `avatar_name`,
             `url`, `location`, `is_following`, `banner_name`)
           VALUES
          ($id, $screen_name, $name, $followers, $following, $tweets,
           $description, $avatar_name, $display_url, $location, $is_following,
           $banner_name);");
          // XXX is_following can only be 1 or 0
    });
  }


  /**
   * Loads the user's banner image.
   *
   * @param base_url The "base url" of the banner, obtained from the users/show call from Twitter.
   * @param user_id Foo
   * @param screen_name Bar
   */
  private void load_profile_banner (string base_url,
                                    int64 user_id, string screen_name) {
    string saved_banner_url = Utils.user_file ("assets/banners/"+get_banner_name (user_id));
    string banner_url  = base_url+"/mobile_retina";
    string banner_name = get_banner_name (user_id);
    string banner_on_disk = Utils.user_file("assets/banners/"+banner_name);
    if (!FileUtils.test (banner_on_disk, FileTest.EXISTS) || banner_url != saved_banner_url) {
      Utils.download_file_async .begin (banner_url, banner_on_disk,
          () => {banner_box.set_background (banner_on_disk);});
        debug("Setting the banner name to %s", banner_name);
      Corebird.db.exec (@"UPDATE `profiles` SET `banner_url`='$banner_url',
          `banner_name`='$banner_name'
          WHERE `id`='$user_id';");
    } else {
      banner_box.set_background (banner_on_disk);
    }
  }


  private new void set_data(string name, string screen_name, string? url,
                            string? location, string description, int tweets,
                            int following, int followers) {

    name_label.set_markup("<big><big><b>%s</b>  @%s</big></big>"
                          .printf(name, screen_name));
//    string d = Tweet.replace_links(description);
    string d = ""; // TODO: Use blablabla
    description_label.set_markup("<big><big><big>%s</big></big></big>".printf(d));
    tweets_button.set_markup(
      "<big><big><b>%'d</b></big></big>\nTweets"
      .printf(tweets));

    following_button.set_markup(
      "<big><big><b>%'d</b></big></big>\nFollowing"
      .printf(following));

    followers_button.set_markup(
      "<big><big><b>%'d</b></big></big>\nFollowers"
      .printf(followers));

    if(location != null && location != ""){
      location_label.visible = true;
      location_label.set_markup("<big><big>%s</big></big>".printf(location));
    }else
      location_label.visible = false;

    if(url != null && url != ""){
      url_label.visible = true;
      url_label.set_markup("<big><big><a href='%s'>%s</a></big></big>"
                         .printf(url, url));
    }else
      url_label.visible = false;

  }

  [GtkCallback]
  private void follow_button_clicked_cb () {
    var call = account.proxy.new_call();
    if (following)
      call.set_function ("1.1/friendships/create.json");
    else
      call.set_function( "1.1/friendships/destroy.json");
    message (@"User ID: $user_id");
    message (user_id.to_string ());
    call.set_method ("POST");
    call.add_param ("follow", "true");
    call.add_param ("id", user_id.to_string ());
    call.invoke_async.begin (null, (obj, res) => {
      try {
      set_follow_button_state (!following);
        call.invoke_async.end (res);
      } catch (GLib.Error e) {
        critical (e.message);
      }
    });
  }

  /*
   * Returns the banner name for the given user by user_id and screen_name.
   * This is useful since both of them might be used for the banner name.
   */
  private string get_banner_name(int64 user_id) {
    return user_id.to_string()+".png";
  }

  private bool handle_uri(string uri){
    uri = uri._strip();
    string term = uri.substring(1);

    if(uri.has_prefix("@")){
      main_window.switch_page(MainWindow.PAGE_PROFILE,
                         int64.parse (term));
      return true;
    }else if(uri.has_prefix("#")){
      main_window.switch_page(MainWindow.PAGE_SEARCH, uri);
      return true;
    }
    return false;
  }

  /**
   * Switch the page to the one with the given ID
   * @param page The page to switch to
   */
  private void switch_page(int page) {
    if(page == active_page)
      return;

    if(page > active_page)
      bottom_stack.transition_type = StackTransitionType.SLIDE_LEFT;
    else
      bottom_stack.transition_type = StackTransitionType.SLIDE_RIGHT;

    bottom_stack.set_visible_child_name("%d".printf(page));
  }


  private void set_follow_button_state (bool following) {
    var sc = follow_button.get_style_context ();
    if (following) {
      sc.remove_class ("suggested-action");
      sc.add_class ("destructive-action");
      follow_button.label = _("Unfollow");
    } else {
      sc.remove_class ("destructive-action");
      sc.add_class ("suggested-action");
      follow_button.label = _("Follow");
    }
    this.following = following;
  }



  /**
   * see IPage#onJoin
   */
  public void on_join(int page_id, va_list arg_list) {
    int64 user_id = arg_list.arg();
    if (user_id == 0)
      return;
    set_user_id(user_id);
  }


  public void create_tool_button(RadioToolButton? group) {}

  public RadioToolButton? get_tool_button(){
    return null;
  }

  public int get_id(){
    return id;
  }
}
