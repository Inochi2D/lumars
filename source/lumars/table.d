module lumars.table;

import std, bindbc.lua, lumars;
import std.traits : isNumeric;

enum LuaIterateOption
{
    none = 0,
    dontDupeStrings = 1 << 0,
}

template ipairs(alias Func, LuaIterateOption Options = LuaIterateOption.none)
{
    void ipairs(LuaTableT)(LuaTableT table)
    {
        const index = table.push();
        scope(exit) table.pop();

        const expectedTop = table.lua.top + 1;
        foreach(i; 1..int.max)
        {
            lua_rawgeti(table.lua.handle, index, i);
            scope(failure) table.lua.pop(1);
            if(lua_isnil(table.lua.handle, -1))
            {
                table.lua.pop(1);
                break;
            }

            LuaValue value;
            const valueType = table.lua.type(-1);
            if(valueType == LuaValue.Kind.text)
            {
                static if((Options & LuaIterateOption.dontDupeStrings) > 0)
                    value = LuaValue(table.lua.get!(const(char)[])(-1));
                else
                    value = LuaValue(table.lua.get!string(-1));
            }
            else
                value = table.lua.get!LuaValue(-1);

            Func(i, value);
            if(table.lua.top != expectedTop)
            {
                table.lua.printStack();
                assert(false, 
                    "Expected stack top to be %s after call to user function, but it is %s."
                    .format(expectedTop, table.lua.top)
                );
            }

            table.lua.pop(1);
        }
    }
}

template ipairs(ValueT, alias Func)
{
    static if(isNumeric!ValueT)
        static assert(is(ValueT == lua_Number), "Please use `LuaNumber` when asking for a numeric type.");
    void ipairs(LuaTableT)(LuaTableT table)
    {
        table.ipairs!((k, v)
        {
            Func(k, v.value!ValueT);
        });
    }
}

template pairs(alias Func, LuaIterateOption Options = LuaIterateOption.none)
{
    void pairs(LuaTableT)(LuaTableT table)
    {
        auto index = table.push();
        scope(exit) table.pop();

        index = index < 0 ? index - 1 : index;

        table.lua.push(null);
        while(table.lua.next(index))
        {
            scope(failure) table.lua.pop(2);

            LuaValue key;
            const keyType = table.lua.type(-2);
            if(keyType == LuaValue.Kind.text)
            {
                static if((Options & LuaIterateOption.dontDupeStrings) > 0)
                    key = LuaValue(table.lua.get!(const(char)[])(-2));
                else
                    key = LuaValue(table.lua.get!string(-2));
            }
            else
                key = table.lua.get!LuaValue(-2);

            LuaValue value;
            const valueType = table.lua.type(-1);
            if(valueType == LuaValue.Kind.text)
            {
                static if((Options & LuaIterateOption.dontDupeStrings) > 0)
                    value = LuaValue(table.lua.get!(const(char)[])(-1));
                else
                    value = LuaValue(table.lua.get!string(-1));
            }
            else
                value = table.lua.get!LuaValue(-1);

            Func(key, value);
            table.lua.pop(1);
        }
    }
}

template pairs(KeyT, ValueT, alias Func)
{
    static if(isNumeric!KeyT)
        static assert(is(KeyT == lua_Number), "Please use `LuaNumber` when asking for a numeric type.");
    static if(isNumeric!ValueT)
        static assert(is(ValueT == lua_Number), "Please use `LuaNumber` when asking for a numeric type.");
    void pairs(LuaTableT)(LuaTableT table)
    {
        table.pairs!((k, v)
        {
            static if(is(KeyT == LuaValue) && is(ValueT == LuaValue))
                Func(k, v);
            else static if(is(KeyT == LuaValue))
                Func(k, v.value!ValueT);
            else static if(is(ValueT == LuaValue))
                Func(k.value!KeyT, v);
            else
                Func(k.value!KeyT, v.value!ValueT);
        });
    }
}

private mixin template LuaTableFuncs()
{
    T get(T, IndexT)(IndexT index)
    if(isNumeric!IndexT || is(IndexT == string))
    {
        static assert(
            !is(IndexT == LuaTableWeak)
        &&  !is(IndexT == LuaFuncWeak)
        &&  !is(IndexT == const(char)[]),
            "Can't use weak references with `get` as this function does not keep the value alive on the stack."
        );

        const meIndex = this.push();
        scope(exit) this.pop();
        
        this.lua.push(index);
        lua_gettable(this.lua.handle, meIndex < 0 ? meIndex - 1 : meIndex);
        auto value = this.lua.get!T(-1);
        this.lua.pop(1);
        return value;
    }

    void set(T, IndexT)(IndexT index, T value)
    if(isNumeric!IndexT || is(IndexT == string))
    {
        const meIndex = this.push();
        scope(exit) this.pop();
        
        this.lua.push(index);
        this.lua.push(value);
        lua_settable(this.lua.handle, meIndex < 0 ? meIndex - 2 : meIndex);
    }

    void setMetatable(LuaTable metatable)
    {
        const meIndex = this.push();
        scope(exit) this.pop();

        metatable.push();
        lua_setmetatable(this.lua.handle, meIndex);
    }

    void opIndexAssign(T, IndexT)(T value, IndexT index)
    {
        this.set(index, value);
    }

    size_t length()
    {
        const index = this.push();
        scope(exit) this.pop();

        return lua_objlen(this.lua.handle, index);
    }
}

struct LuaTablePseudo
{
    private
    {
        LuaState* _lua;
        int _index;
    }

    @safe @nogc
    this(LuaState* lua, int index) nothrow
    {
        this._index = index;
        this._lua = lua;
    }

    void pushElement(IndexT)(IndexT index)
    if(isNumeric!IndexT || is(IndexT == string))
    {
        this.lua.push(index);
        lua_gettable(this.lua.handle, this._index);
    }

    T get(T, IndexT)(IndexT index)
    if(isNumeric!IndexT || is(IndexT == string))
    {
        static assert(
            !is(IndexT == LuaTableWeak)
        &&  !is(IndexT == LuaFuncWeak)
        &&  !is(IndexT == const(char)[]),
            "Can't use weak references with `get` as this function does not keep the value alive on the stack."
        );

        this.lua.push(index);
        lua_gettable(this.lua.handle, this._index);
        auto value = this.lua.get!T(-1);
        this.lua.pop(1);
        return value;
    }

    void set(T, IndexT)(IndexT index, T value)
    if(isNumeric!IndexT || is(IndexT == string))
    {        
        this.lua.push(index);
        this.lua.push(value);
        lua_settable(this.lua.handle, this._index);
    }

    void opIndexAssign(T, IndexT)(T value, IndexT index)
    {
        this.set(index, value);
    }

    @property @safe @nogc
    LuaState* lua() nothrow pure
    {
        return this._lua;
    }
}

struct LuaTableWeak 
{
    mixin LuaTableFuncs;

    private
    {
        LuaState* _lua;
        int _index;
    }

    this(LuaState* lua, int index)
    {
        lua.enforceType(LuaValue.Kind.table, index);
        this._index = index;
        this._lua = lua;
    }    
    
    void pushElement(IndexT)(IndexT index)
    if(isNumeric!IndexT || is(IndexT == string))
    {
        this.lua.push(index);
        lua_gettable(this.lua.handle, this._index < 0 ? this._index - 1 : this._index);
    }

    @safe @nogc 
    int push() nothrow pure const
    {
        return this._index;
    }

    void pop()
    {
        this.lua.enforceType(LuaValue.Kind.table, this._index);
    }

    @property @safe @nogc
    LuaState* lua() nothrow pure
    {
        return this._lua;
    }
}

struct LuaTable 
{
    mixin LuaTableFuncs;

    private
    {
        static struct State
        {
            LuaState* lua;
            int ref_;
            
            ~this()
            {
                if(this.lua)
                    luaL_unref(this.lua.handle, LUA_REGISTRYINDEX, this.ref_);
            }
        }
        RefCounted!State _state;
    }

    void pushElement(IndexT)(IndexT index)
    if(isNumeric!IndexT || is(IndexT == string))
    {
        this.push();
        scope(exit) this.lua.remove(-2);

        this.lua.push(index);
        lua_gettable(this.lua.handle, -2);
    }

    static LuaTable makeRef(LuaState* lua)
    {
        lua.enforceType(LuaValue.Kind.table, -1);
        RefCounted!State state;
        state.lua = lua;
        state.ref_ = luaL_ref(lua.handle, LUA_REGISTRYINDEX);

        return LuaTable(state);
    }

    static LuaTable makeNew(LuaState* lua, int arrayCapacity = 0, int recordCapacity = 0)
    {
        lua_createtable(lua.handle, arrayCapacity, recordCapacity);
        return LuaTable.makeRef(lua);
    }

    static LuaTable makeNew(Range)(LuaState* lua, Range range)
    if(isInputRange!Range)
    {
        alias Element = ElementType!Range;

        lua_newtable(lua.handle);
        static if(is(Element == struct) && __traits(hasMember, Element, "key") && __traits(hasMember, Element, "value"))
        {
            foreach(kvp; range)
            {
                lua.push(kvp.key);
                lua.push(kvp.value);
                lua.rawSet(-3);
            }
        }
        else
        {
            int i = 1;
            foreach(v; range)
            {
                lua.push(v);
                lua.rawSet(-2, i++);
            }
        }

        return LuaTable.makeRef(lua);
    }

    static LuaTable makeNew(AA)(LuaState* lua, AA aa)
    if(isAssociativeArray!AA)
    {
        return makeNew(lua, aa.byKeyValue);
    }

    @nogc
    int push() nothrow
    {
        lua_rawgeti(this._state.lua.handle, LUA_REGISTRYINDEX, this._state.ref_);
        return this._state.lua.top;
    }

    void pop()
    {
        this._state.lua.enforceType(LuaValue.Kind.table, -1);
        this._state.lua.pop(1);
    }

    LuaState* lua()
    {
        return this._state.lua;
    }
}

unittest
{
    auto l = LuaState(null);

    l.push(["Henlo, ", "Warld."]);
    auto t = l.get!LuaTableWeak(-1);
    int i = 0;
    t.ipairs!((k, v)
    {
        i++;
        assert(
            (k == 1 && v.textValue == "Henlo, ")
         || (k == 2 && v.textValue == "Warld."),
         format("%s, %s", k, v)
        );
    });
    assert(t.get!string(1) == "Henlo, ");
    assert(t.get!string(2) == "Warld.");
    assert(i == 2);
    t.ipairs!(string, (k, v)
    {
        if(k == 1)
            assert(v == "Henlo, ");
    });
    l.pop(1);
}

unittest
{
    auto l = LuaState(null);

    l.push(
        [
            "a": "bc",
            "1": "23"
        ]
    );
    auto t = l.get!LuaTable(-1);
    int i = 0;
    t.pairs!((k, v)
    {
        i++;
        assert(
            (k.textValue == "a" && v.textValue == "bc")
         || (k.textValue == "1" && v.textValue == "23"),
         format("%s, %s", k, v)
        );
    });
    assert(t.get!string("a") == "bc");
    assert(t.get!string("1") == "23");
    assert(i == 2);
    l.pop(1);
}

unittest
{
    auto l = LuaState(null);
    auto t = LuaTable.makeNew(&l);

    t["test"] = "icles";
    t[4] = 20;
    assert(t.get!string("test") == "icles");
    assert(t.get!LuaNumber(4) == 20);
}

unittest
{
    auto l = LuaState(null);
    auto t = LuaTable.makeNew(&l, iota(1, 11));
    assert(t.length == 10);
    t.ipairs!(LuaNumber, (i, v)
    {
        assert(i == v);
    });
}

unittest
{
    auto l = LuaState(null);
    auto t = LuaTable.makeNew(&l, ["a": "bc", "1": "23"]);

    int count;
    t.pairs!(string, string, (k, v)
    {
        if(k == "a")
            assert(v == "bc");
        else if(k == "1")
            assert(v == "23");
        else
            assert(false);
        count++;
    });
    assert(count == 2);
}

unittest
{
    auto l = LuaState(null);
    auto t = LuaTable.makeNew(&l);
    t["__call"] = &luaCWrapperSmart!(() => 2);
    auto t2 = LuaTable.makeNew(&l);
    t2.setMetatable(t);

    l.globalTable["test"] = t2;
    l.doString("assert(test() == 2)");
}