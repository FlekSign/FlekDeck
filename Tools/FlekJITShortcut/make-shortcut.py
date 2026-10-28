#!/usr/bin/env python3
#
# Writes the "FlekJIT" shortcut that FlekDeck runs to switch Mobile Data off
# while JIT starts and back on after (FlekMobileDataShortcut.swift). The text
# it is run with decides:
#
#   "off"         Set Mobile Data off
#   "on"          Set Mobile Data on
#   anything else nothing, which is how FlekDeck tries it out
#
# What this writes is not signed, and the Shortcuts app adds only a signed
# one. To replace the copy FlekDeck carries, on a Mac signed in to iCloud:
#
#   python3 Tools/FlekJITShortcut/make-shortcut.py /tmp/unsigned/FlekJIT.shortcut
#   shortcuts sign --mode anyone --input /tmp/unsigned/FlekJIT.shortcut \
#       --output Resources/Assets.xcassets/FlekJITShortcut.dataset/FlekJIT.shortcut
#
# "anyone" has Apple sign it, with nothing of the account in the file. The
# signing certificate runs for about two years: the copy made on 14 Oct 2026
# is good until 11 Nov 2027, and has to be signed again before then.
#
# The file keeps the name FlekJIT.shortcut: the Shortcuts app names a shortcut
# after the file it is added from, and FlekDeck runs it by that name. The
# actions are written as iOS 27 exports them.
#

import plistlib
import sys
import uuid


def new_id():
    return str(uuid.uuid4()).upper()


def action(identifier, **parameters):
    return {"WFWorkflowActionIdentifier": identifier, "WFWorkflowActionParameters": parameters}


# The text the shortcut is run with, as a Text action: Shortcut Input itself
# has no type, and If can only ask of it whether it has any value.
text_id = new_id()
text = action("is.workflow.actions.gettext", UUID=text_id, WFTextActionText={
    "Value": {"string": "￼", "attachmentsByRange": {"{0, 1}": {"Type": "ExtensionInput"}}},
    "WFSerializationType": "WFTextTokenString",
})
text_output = {
    "Type": "Variable",
    "Variable": {
        "Value": {"OutputUUID": text_id, "Type": "ActionOutput", "OutputName": "Text"},
        "WFSerializationType": "WFTextTokenAttachment",
    },
}


def when_text_contains(word, *then):
    group = new_id()
    return [
        # 99 is "contains", and the modes are 0 for If and 2 for End If.
        action("is.workflow.actions.conditional", WFInput=text_output, WFControlFlowMode=0,
               WFConditionalActionString=word, GroupingIdentifier=group, WFCondition=99),
        *then,
        action("is.workflow.actions.conditional", UUID=new_id(), GroupingIdentifier=group, WFControlFlowMode=2),
    ]


workflow = {
    "WFWorkflowMinimumClientVersionString": "900",
    "WFWorkflowMinimumClientVersion": 900,
    "WFWorkflowIcon": {"WFWorkflowIconStartColor": 463140863, "WFWorkflowIconGlyphNumber": 61440},
    "WFWorkflowClientVersion": "5037.109",
    "WFWorkflowOutputContentItemClasses": [],
    "WFWorkflowHasOutputFallback": False,
    # As the Shortcuts app writes them for a new shortcut.
    "WFWorkflowInputContentItemClasses": [
        "WFAppContentItem", "WFAppStoreAppContentItem", "WFArticleContentItem", "WFContactContentItem",
        "WFDateContentItem", "WFEmailAddressContentItem", "WFFolderContentItem", "WFGenericFileContentItem",
        "WFImageContentItem", "WFiTunesProductContentItem", "WFLocationContentItem", "WFDCMapsLinkContentItem",
        "WFAVAssetContentItem", "WFPDFContentItem", "WFPhoneNumberContentItem", "WFRichTextContentItem",
        "WFSafariWebPageContentItem", "WFStringContentItem", "WFURLContentItem",
    ],
    "WFWorkflowTypes": ["WFWorkflowTypeShowInSearch"],
    "WFQuickActionSurfaces": [],
    "WFWorkflowImportQuestions": [],
    "WFWorkflowHasShortcutInputVariables": True,
    "WFWorkflowActions": [
        text,
        # Off is OnValue 0, and on is the action as it comes.
        *when_text_contains("off", action("is.workflow.actions.cellulardata.set", OnValue=0)),
        *when_text_contains("on", action("is.workflow.actions.cellulardata.set")),
    ],
}

if len(sys.argv) != 2:
    sys.exit("usage: make-shortcut.py <where to write FlekJIT.shortcut>")
with open(sys.argv[1], "wb") as file:
    plistlib.dump(workflow, file, fmt=plistlib.FMT_BINARY)
