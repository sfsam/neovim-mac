//
//  ui.cpp
//  Neovim
//
//  Created by Jay Sandhu on 4/8/20.
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//

#include <algorithm>
#include <utility>
#include <iostream>
#include <type_traits>

#include "log.h"
#include "ui.hpp"

namespace ui {
namespace {

void log_grid_out_of_bounds(const grid *grid, const char *event,
                            size_t row, size_t col) {
    os_log_error(rpc, "Redraw error: Grid index out of bounds - "
                      "Event=%s, Grid=%zux%zu, Index=[row=%zu, col=%zu]",
                      event, grid->width, grid->height, row, col);
}

template<typename T>
bool is(const msg::object &object) {
    if constexpr (!std::is_same_v<T, msg::boolean> && std::is_integral_v<T>) {
        return object.is<msg::integer>();
    } else {
        return object.is<T>();
    }
}

template<typename T>
T get(const msg::object &object) {
    if constexpr (!std::is_same_v<T, msg::boolean> && std::is_integral_v<T>) {
        return object.get<msg::integer>().as<T>();
    } else {
        return object.get<T>();
    }
}

template<typename ...Ts, size_t ...Indexes>
void call(ui_state &state,
          void(ui_state::*member_function)(Ts...),
          const msg::array &array,
          std::integer_sequence<size_t, Indexes...>) {
    (state.*member_function)(get<Ts>(array[Indexes])...);
}

template<typename ...Ts>
void apply_one(ui_state *state,
               void(ui_state::*member_function)(Ts...),
               const msg::string &name, const msg::object &object) {
    if (object.is<msg::array>()) {
        msg::array args = object.get<msg::array>();
        
        constexpr size_t size = sizeof...(Ts);
        size_t index = 0;
        
        if (size <= args.size() && (is<Ts>(args[index++]) && ...)) {
            return call(*state, member_function, args,
                        std::make_integer_sequence<size_t, size>());
        }
    }
    
    os_log_error(rpc, "Redraw error: Argument type error - "
                      "Event=%.*s, ArgTypes=%s",
                      (int)name.size(), name.data(),
                      msg::type_string(object).c_str());
}

template<typename ...Ts>
void apply(ui_state *state,
           void(ui_state::*member_function)(Ts...),
           const msg::string &name, const msg::array &array) {
    for (const msg::object &tuple : array) {
        apply_one(state, member_function, name, tuple);
    }
}

inline cell make_cell(const msg::string &text,
                      const highlight_attributes *hl_attrs) {
    cell ret = {};
    ret.hl_attrs = *hl_attrs;
    
    if (text.size() == 1 && *text.data() == ' ') {
        return ret;
    }
    
    size_t limit = std::min(text.size(), cell::max_text_size);
    ret.hash = 5381;
    ret.size = limit;
    
    // TODO: Should we validate UTF-8 here?
    for (size_t i=0; i<limit; ++i) {
        ret.text[i] = text[i];
        ret.hash = (ret.hash * 33) + text[i];
    }
    
    return ret;
}

} // namespace

grid* ui_state::get_grid(size_t index) {
    if (index != 1) {
        std::abort();
    }
    
    return writing;
}

void ui_state::redraw_event(const msg::object &event_object) {
    const msg::array *event = event_object.get_if<msg::array>();
    
    if (!event || !event->size() || !event->at(0).is<msg::string>()) {
        return os_log_error(rpc, "Redraw error: Event type error - Type=%s",
                            msg::type_string(event_object).c_str());
    }
    
    msg::string name = event->at(0).get<msg::string>();
    msg::array args = event->subarray(1);
    
    if (name == "grid_line") {
        return apply(this, &ui_state::grid_line, name, args);
    } else if (name == "grid_resize") {
        return apply(this, &ui_state::grid_resize, name, args);
    } else if (name == "grid_scroll") {
        return apply(this, &ui_state::grid_scroll, name, args);
    } else if (name == "flush") {
        return apply(this, &ui_state::flush, name, args);
    } else if (name == "grid_clear") {
        return apply(this, &ui_state::grid_clear, name, args);
    } else if (name == "hl_attr_define") {
        return apply(this, &ui_state::hl_attr_define, name, args);
    } else if (name == "default_colors_set") {
        return apply(this, &ui_state::default_colors_set, name, args);
    } else if (name == "mode_info_set") {
        return apply(this, &ui_state::mode_info_set, name, args);
    } else if (name == "mode_change") {
        return apply(this, &ui_state::mode_change, name, args);
    }
    
    os_log_info(rpc, "Redraw info: Unhandled event - Name=%.*s Args=%s",
                (int)std::min(name.size(), 128ul), name.data(),
                msg::to_string(args).c_str());
}

void ui_state::redraw(msg::array events) {
    for (const msg::object &event : events) {
        redraw_event(event);
    }
}

void ui_state::grid_resize(size_t grid_id, size_t width, size_t height) {
    grid *grid = get_grid(grid_id);
    grid->resize(width, height);
}

template<typename ...Ts>
static bool type_check(const msg::array &array) {
    size_t index = 0;
    return array.size() == sizeof...(Ts) && (array[index++].is<Ts>() && ...);
}

struct cell_update {
    msg::string text;
    const highlight_attributes *hlattr;
    size_t repeat;
    
    cell_update(): hlattr(nullptr), repeat(0) {}
    
    bool set(const msg::object &object, const highlight_table &hl_table) {
        if (!object.is<msg::array>()) {
            return false;
        }
        
        msg::array array = object.get<msg::array>();
        
        if (type_check<msg::string>(array)) {
            text = array[0].get<msg::string>();
            repeat = 1;
            return true;
        }
        
        if (type_check<msg::string, msg::integer>(array)) {
            text = array[0].get<msg::string>();
            hlattr = hl_table.get_entry(array[1].get<msg::integer>());
            repeat = 1;
            return true;
        }
            
        if (type_check<msg::string, msg::integer, msg::integer>(array)) {
            text = array[0].get<msg::string>();
            hlattr = hl_table.get_entry(array[1].get<msg::integer>());
            repeat = array[2].get<msg::integer>();
            return true;
        }
        
        return false;
    }
};

void ui_state::grid_line(size_t grid_id, size_t row,
                         size_t col, msg::array cells) {
    grid *grid = get_grid(grid_id);
    
    if (row >= grid->height || col >= grid->width) {
        return log_grid_out_of_bounds(grid, "grid_line", row, col);
    }
    
    cell *cell = grid->get(row, col);
    size_t remaining = grid->width - col;
    cell_update update;
    
    for (const msg::object &object : cells) {
        if (!update.set(object, hltable)) {
            return os_log_error(rpc, "Redraw error: Cell update type error - "
                                     "Event=grid_line, Type=%s",
                                     msg::type_string(object).c_str());
        }
        
        if (!update.hlattr) {
            return os_log_error(rpc, "Redraw error: Unknown highlight id - "
                                     "Event=grid_line");
        }
        
        if (update.repeat > remaining) {
            return os_log_error(rpc, "Redraw error: Row overflow - "
                                     "Event=grid_line");
        }
        
        *cell = make_cell(update.text, update.hlattr);
        
        for (int i=1; i<update.repeat; ++i) {
            cell[i] = *cell;
        }
        
        cell += update.repeat;
        remaining -= update.repeat;
    }
}

void ui_state::grid_clear(size_t grid_id) {
    grid *grid = get_grid(grid_id);
    cell empty = {};
    empty.hl_attrs.background = hltable.get_default()->background;

    for (cell &cell : grid->cells) {
        cell = empty;
    }
}

void ui_state::grid_scroll(size_t grid_id, size_t top, size_t bottom,
                           size_t left, size_t right, long rows) {
    if (bottom < top || right < left) {
        os_log_error(rpc, "Redraw error: Invalid args - "
                          "Event=grid_scroll, "
                          "Args=[top=%zu, bottom=%zu, left=%zu, right=%zu]",
                          top, bottom, left, right);
        return;
    }
    
    grid *grid = get_grid(grid_id);
    size_t height = bottom - top;
    size_t width = right - left;
    
    if (bottom > grid->height || right > grid->width) {
        return log_grid_out_of_bounds(grid, "grid_scroll", bottom, right);
    }
    
    long count;
    long row_width;
    cell *dest;
    
    if (rows >= 0) {
        dest = grid->get(top, left);
        row_width = grid->width;
        count = height - rows;
    } else {
        dest = grid->get(bottom - 1, left);
        row_width = -grid->width;
        count = height + rows;
    }

    cell *src = dest + ((long)grid->width * rows);
    size_t copy_size = sizeof(cell) * width;
    
    for (long i=0; i<count; ++i) {
        memcpy(dest, src, copy_size);
        dest += row_width;
        src += row_width;
    }
}

void grid::resize(size_t new_width, size_t new_heigth) {
    width = new_width;
    height = new_heigth;
    cells.resize(new_width * new_heigth);
}

void ui_state::flush() {
    grid *completed = writing;
    completed->draw_tick += 1;
    
    writing = complete.exchange(completed);
    *writing = *completed;
    window.redraw();
}

highlight_attributes* highlight_table::new_entry(size_t hlid) {
    const size_t table_size = table.size();
    
    if (hlid == table_size) {
        table.push_back(*get_default());
        return &table.back();
    }
    
    if (hlid < table_size) {
        table[hlid] = *get_default();
        return &table[hlid];
    }
        
    highlight_attributes default_attrs = *get_default();
    table.resize(hlid, default_attrs);
    return &table.back();
}

void ui_state::default_colors_set(uint32_t fg, uint32_t bg, uint32_t sp) {
    rgb_color rgb_fg(fg, rgb_color::default_tag);
    rgb_color rgb_bg(bg, rgb_color::default_tag);
    rgb_color rgb_sp(sp, rgb_color::default_tag);
     
    highlight_attributes *def = hltable.get_default();
    def->foreground = rgb_fg;
    def->background = rgb_bg;
    def->special = rgb_sp;
    def->fontattrs = {};
    def->attrs = {};
    
    // TODO: handle reversed cells
    for (cell &cell : writing->cells) {
        if (cell.hl_attrs.foreground.is_default()) {
            cell.hl_attrs.foreground = rgb_fg;
        }
        
        if (cell.hl_attrs.background.is_default()) {
            cell.hl_attrs.background = rgb_bg;
        }
        
        if (cell.hl_attrs.special.is_default()) {
            cell.hl_attrs.special = rgb_sp;
        }
    }
}

static inline void set_rgb_color(rgb_color &color, const msg::object &object) {
    if (!object.is<msg::integer>()) {
        return os_log_error(rpc, "Redraw error: RGB type error - "
                                 "Event=hl_attr_define, Type=%s",
                                 msg::type_string(object).c_str());
    }
    
    uint32_t rgb = object.get<msg::integer>().as<uint32_t>();
    color = rgb_color(rgb);
}

void ui_state::hl_attr_define(size_t hlid, msg::map definition) {
    highlight_attributes *hlattrs = hltable.new_entry(hlid);
    bool reversed = false;
    
    for (const msg::pair &pair : definition) {
        if (!pair.first.is<msg::string>()) {
            os_log_error(rpc, "Redraw error: Map key type error - "
                              "Event=hl_attr_define, Type=%s",
                              msg::type_string(pair.first).c_str());
            continue;
        }

        msg::string name = pair.first.get<msg::string>();

        if (name == "foreground") {
            set_rgb_color(hlattrs->foreground, pair.second);
        } else if (name == "background") {
            set_rgb_color(hlattrs->background, pair.second);
        } else if (name == "underline") {
            hlattrs->attrs.underline = true;
        } else if (name == "bold") {
            hlattrs->fontattrs.bold = true;
        } else if (name == "italic") {
            hlattrs->fontattrs.italic = true;
        } else if (name == "strikethrough") {
            hlattrs->attrs.strikethrough = true;
        } else if (name == "undercurl") {
            hlattrs->attrs.undercurl = true;
        } else if (name == "special") {
            set_rgb_color(hlattrs->special, pair.second);
        } else if (name == "reverse") {
            reversed = true;
            hlattrs->attrs.reverse = true;
        } else {
            os_log_info(rpc, "Redraw info: Ignoring highlight attribute - "
                             "Event=hl_attr_define, Name=%.*s",
                             (int)name.size(), name.data());
        }
    }
    
    if (reversed) {
        std::swap(hlattrs->background, hlattrs->foreground);
    }
}

static inline cursor_shape to_cursor_shape(const msg::object &object) {
    if (object.is<msg::string>()) {
        msg::string name = object.get<msg::string>();
        
        if (name == "block") {
            return cursor_shape::block;
        } else if (name == "vertical") {
            return cursor_shape::vertical;
        } else if (name == "horizontal") {
            return cursor_shape::horizontal;
        }
    }
    
    os_log_error(rpc, "Redraw error: Unknown cursor shape - "
                      "Event=mode_info_set CursorShape=%s",
                      msg::to_string(object).c_str());

    return cursor_shape::gui_default;
};

static inline void set_color_attrs(cursor_attributes *attrs,
                                   const highlight_table &hl_table,
                                   const msg::object &object) {
    if (!object.is<msg::integer>()) {
        os_log_error(rpc, "Redraw error: Highlight id type error - "
                          "Event=mode_info_set, Type=%s",
                          msg::type_string(object).c_str());
        return;
    }
    
    const size_t hlid = object.get<msg::integer>();
    const highlight_attributes *hl_attrs = hl_table.get_entry(hlid);
    attrs->foreground = hl_attrs->foreground;
    attrs->background = hl_attrs->background;
}

template<typename T>
static inline T to(const msg::object &object) {
    if (is<T>(object)) {
        return get<T>(object);
    }
    
    return {};
}

static cursor_attributes to_cursor_attributes(const highlight_table &hl_table,
                                              const msg::map &map) {
    cursor_attributes attrs;
    
    for (const msg::pair &pair : map) {
        if (!pair.first.is<msg::string>()) {
            os_log_error(rpc, "Redraw error: Map key type error - "
                              "Event=mode_info_set, Type=%s",
                              msg::type_string(pair.first).c_str());
            continue;
        }
        
        msg::string name = pair.first.get<msg::string>();
        
        if (name == "cursor_shape") {
            attrs.shape = to_cursor_shape(pair.second);
        } else if (name == "cell_percentage") {
            attrs.percentage = to<uint16_t>(pair.second);
        } else if (name == "blinkwait") {
            attrs.blinkwait = to<uint16_t>(pair.second);
        } else if (name == "blinkon") {
            attrs.blinkon = to<uint16_t>(pair.second);
        } else if (name == "blinkoff") {
            attrs.blinkoff = to<uint16_t>(pair.second);
        } else if (name == "name") {
            attrs.mode_name = to<msg::string>(pair.second);
        } else if (name == "attr_id") {
            set_color_attrs(&attrs, hl_table, pair.second);
        }
    }
    
    return attrs;
}

void ui_state::mode_info_set(bool enabled, msg::array property_maps) {
    cursor_table.clear();
    cursor_table.reserve(property_maps.size());
    current_mode = 0;
    
    for (const msg::object &object : property_maps) {
        if (!object.is<msg::map>()) {
            os_log_error(rpc, "Redraw error: Cursor property map type error - "
                              "Event=mode_info_set, Type=%s",
                              msg::type_string(object).c_str());
            continue;
        }
        
        msg::map map = object.get<msg::map>();
        cursor_table.push_back(to_cursor_attributes(hltable, map));
    }
}

void ui_state::mode_change(msg::string name, size_t index) {
    if (index >= cursor_table.size()) {
        return os_log_error(rpc, "Redraw error: Mode index out of bounds - "
                                 "Event=mode_change, TableSize=%zu, Index=%zu",
                                 cursor_table.size(), index);
    }
    
    current_mode = index;
}

} // namespace ui
