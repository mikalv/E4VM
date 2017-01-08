//
// This is an open source non-commercial project. Dear PVS-Studio, please check it.
// PVS-Studio Static Code Analyzer for C, C++ and C#: http://www.viva64.com
//

#include "g_erts/box.h"
#include "g_erts/term.h"

namespace gluon {

Term Term::empty_tuple_ = BoxHeader(BoxTag::Tuple, 0);

Term Term::make_tuple(BoxHeader *box_contents) {
    // Assumption: boxheader already has tuple tag and arity set
    G_ASSERT(box_contents->tag() == BoxTag::Tuple);
    G_ASSERT(box_contents->arity() > 0);
    return box_wrap(box_contents);
}

BoxHeader::operator Term() const { return Term(val_); }

} // ns gluon
