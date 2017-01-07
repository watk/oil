#!/usr/bin/env python3
"""
py_meta.py

Parse an ASDL file, and generate Python classes using metaprogramming.
All objects descends from Obj, which allows them to be dynamically type-checked
and serialized.  Objects hold type descriptors, which are defined in asdl.py.

Usage:
  from osh import ast_ as ast

  n1 = ast.ArithVar()
  n2 = ast.ArrayLiteralPart()

API Notes:

The Python AST module doesn't make any distinction between simple and compound
sum types.  (Simple types have no constructors with fields.)

C++ has to make this distinction for reasons of representation.  It's more
efficient to hold an enum value than a pointer to a class with an enum value.
In Python I guess that's not quite true.

So in order to serialize the correct bytes for C++, our Python metaclass
implementation has to differ from what's generated by asdl_c.py.  More simply
put: an op is Add() and not Add, an instance of a class, not an integer value.
"""

import io
import sys

from asdl import format as fmt
from asdl import asdl_ as asdl  # ALIAS for nodes


def _CheckType(value, expected_desc):
  """Is value of type expected_desc?

  Args:
    value: Obj or primitive type
    expected_desc: instance of asdl.Product, asl.Sum, asdl.StrType,
      asdl.IntType, ArrayType, MaybeType, etc.
  """
  if isinstance(expected_desc, asdl.Constructor):
    # This doesn't make sense because the descriptors are derived from the
    # declared types.  You can declare a field as arith_expr_e but not
    # ArithBinary.
    raise AssertionError("Invalid Constructor descriptor")

  if isinstance(expected_desc, asdl.MaybeType):
    if value is None:
      return True
    return _CheckType(value, expected_desc.desc)

  if isinstance(expected_desc, asdl.ArrayType):
    if not isinstance(value, list):
      return False
    # Now check all entries
    for item in value:
      if not _CheckType(item, expected_desc.desc):
        return False
    return True

  if isinstance(expected_desc, asdl.StrType):
    return isinstance(value, str)

  if isinstance(expected_desc, asdl.IntType):
    return isinstance(value, int)

  if isinstance(expected_desc, asdl.BoolType):
    return isinstance(value, bool)

  if isinstance(expected_desc, asdl.UserType):
    return isinstance(value, expected_desc.typ)

  try:
    actual_desc = value.__class__.DESCRIPTOR
  except AttributeError:
    return False  # it's not of the right type

  if isinstance(expected_desc, asdl.Product):
    return actual_desc is expected_desc

  if isinstance(expected_desc, asdl.Sum):
    if asdl.is_simple(expected_desc):
      return actual_desc is expected_desc
    else:
      for cons in expected_desc.types:
        #print("CHECKING desc %s against %s" % (desc, cons))
        # It has to be one of the alternatives
        if actual_desc is cons:
          return True
      return False

  raise AssertionError(
      'Invalid descriptor %r: %r' % (expected_desc.__class__, expected_desc))


class Obj:
  # NOTE: We're using CAPS for these static fields, since they are constant at
  # runtime after metaprogramming.
  DESCRIPTOR = None  # Used for type checking


class SimpleObj(Obj):
  """An enum value.

  Other simple objects: int, str, maybe later a float.
  """
  def __init__(self, enum_id, name):
    self.enum_id = enum_id
    self.name = name

  def __repr__(self):
    return '<%s %s %s>' % (self.__class__.__name__, self.name, self.enum_id)


class CompoundObj(Obj):
  """A compound object with fields, e.g. a Product or Constructor.

  Uses some metaprogramming.
  """
  FIELDS = []  # ordered list of field names
  DESCRIPTOR_LOOKUP = {}  # field name: (asdl.Type | int | str)

  # Always set for constructor types, which are subclasses of sum types.  Never
  # set for product types.
  tag = None

  def __init__(self, *args, **kwargs):
    # The user must specify ALL required fields or NONE.
    self._assigned = {f: False for f in self.FIELDS}
    self._SetDefaults()
    if args or kwargs:
      self._Init(args, kwargs)

  def __eq__(self, other):
    if not isinstance(other, CompoundObj):
      return False

    if self.tag != other.tag:
      return False

    for name in self.FIELDS:
      # Special case: we are not testing locations right now.
      if name == 'loc':
        continue
      left = getattr(self, name)
      right = getattr(other, name)
      if left != right:
        return False

    return True

  def _SetDefaults(self):
    for name in self.FIELDS:
      #print("%r wasn't assigned" % name)
      desc = self.DESCRIPTOR_LOOKUP[name]
      # item_desc = desc.desc
      if isinstance(desc, asdl.MaybeType):
        self.__setattr__(name, None)  # Maybe values can be None
      elif isinstance(desc, asdl.ArrayType):
        self.__setattr__(name, [])

  def _Init(self, args, kwargs):
    for i, val in enumerate(args):
      name = self.FIELDS[i]
      self.__setattr__(name, val)

    for name, val in kwargs.items():
      if self._assigned[name]:
        raise AssertionError('Duplicate assignment of field %r' % name)
      self.__setattr__(name, val)

    for name in self.FIELDS:
      if not self._assigned[name]:
        # If anything was set, then required fields raise an error.
        raise ValueError("Field %r is required and wasn't initialized" % name)

  def CheckUnassigned(self):
    """See if there are unassigned fields, for later encoding."""
    unassigned = []
    for name in self.FIELDS:
      if not self._assigned[name]:
        desc = self.DESCRIPTOR_LOOKUP[name]
        if not isinstance(desc, asdl.MaybeType):
          unassigned.append(name)
    if unassigned:
      raise ValueError("Fields %r were't be assigned" % unassigned)

  def __setattr__(self, name, value):
    if name == '_assigned':
      self.__dict__[name] = value
      return
    try:
      desc = self.DESCRIPTOR_LOOKUP[name]
    except KeyError:
      raise AttributeError('Object of type %r has no attribute %r' %
                           (self.__class__.__name__, name))

    if not _CheckType(value, desc):
      raise AssertionError("Field %r should be of type %s, got %r (%s)" %
                           (name, desc, value, value.__class__))

    self._assigned[name] = True  # check this later when encoding
    self.__dict__[name] = value

  def __repr__(self):
    # For the console
    f = fmt.AnsiOutput(io.StringIO())
    #f = fmt.HtmlOutput(io.StringIO())
    tree = fmt.MakeTree(self)
    fmt.PrintTree(tree, f)
    s, _ = f.GetRaw()
    return s


def _MakeFieldDescriptors(module, fields, app_types):
  desc_lookup = {}
  for f in fields:
    # look up type by name
    primitive_desc = asdl.DESCRIPTORS_BY_NAME.get(f.type)
    app_desc = app_types.get(f.type)

    # Lookup order: primitive, defined in the ASDL file, passed by the app
    desc = primitive_desc or module.types.get(f.type) or app_desc
    # It's either a primitive type or sum type
    if primitive_desc is None and app_desc is None:
      assert (isinstance(desc, asdl.Sum) or
          isinstance(desc, asdl.Product)), 'field %s has descriptor %s' % (f, desc)

    # Wrap descriptor here.  Then we can type check.
    # And then encode too.
    assert not (f.opt and f.seq), f
    if f.opt:
      desc = asdl.MaybeType(desc)

    if f.seq:
      desc = asdl.ArrayType(desc)

    desc_lookup[f.name] = desc

  class_attr = {
      'FIELDS': [f.name for f in fields],
      'DESCRIPTOR_LOOKUP': desc_lookup,
  }
  return class_attr


def MakeTypes(module, root, app_types=None):
  """
  Args:
    module: asdl.Module
    root: an object/package to add types to
  """
  app_types = app_types or {}
  for defn in module.dfns:
    typ = defn.value

    #print('TYPE', defn.name, typ)
    if isinstance(typ, asdl.Sum):
      sum_type = typ
      if asdl.is_simple(sum_type):
        # An object without fields, which can be stored inline.
        class_attr = {'DESCRIPTOR': sum_type}  # asdl.Sum
        cls = type(defn.name, (SimpleObj, ), class_attr)
        #print('CLASS', cls)
        setattr(root, defn.name, cls)

        for i, cons in enumerate(sum_type.types):
          enum_id = i + 1
          name = cons.name
          val = cls(enum_id, cons.name)  # Instantiate SimpleObj subtype
          # Set a static attribute like op_id.Plus, op_id.Minus.
          setattr(cls, name, val)
      else:
        tag_num = {}

        # e.g. for arith_expr
        base_class = type(defn.name, (CompoundObj, ), {})
        setattr(root, defn.name, base_class)

        # Make a type and a enum tag for each alternative.
        for i, cons in enumerate(sum_type.types):
          tag = i + 1  # zero reserved?
          tag_num[cons.name] = tag  # for enum

          class_attr = _MakeFieldDescriptors(module, cons.fields, app_types)
          class_attr['DESCRIPTOR'] = cons  # asdl.Constructor
          class_attr['tag'] = tag

          cls = type(cons.name, (base_class, ), class_attr)
          #cls.DESCRIPTOR = cls  # CIRCULAR, for type checking.
                                # TODO: Consider a different scheme.

          setattr(root, cons.name, cls)

        # e.g. arith_expr_e.Const == 1
        enum_name = defn.name + '_e'
        tag_enum = type(enum_name, (), tag_num)
        setattr(root, enum_name, tag_enum)

    elif isinstance(typ, asdl.Product):
      class_attr = _MakeFieldDescriptors(module, typ.fields, app_types)
      # TODO: Descriptor should be cls, like above?
      class_attr['DESCRIPTOR'] = typ

      cls = type(defn.name, (CompoundObj, ), class_attr)
      setattr(root, defn.name, cls)

    else:
      raise AssertionError(typ)
