"""Attachment guides in percentages of each painting, x right, y down.
Each pair is the proximal and distal end of one visible bone. Occluded bones
retain their parent's transform but own no pixels in that projection.
"""
PARENTS = {'trunk':None,'chest':'trunk','head':'chest','tail':'trunk','tip':'tail',
           'rear':'trunk','rearFoot':'rear','farRear':'trunk','farRearFoot':'farRear',
           'arm':'chest','forearm':'arm','paw':'forearm','farArm':'chest','farForearm':'farArm','farPaw':'farForearm'}
PARENTS.update({'nearShin':'rear','nearHock':'nearShin','nearHindPaw':'nearHock',
                'farShin':'farRear','farHock':'farShin','farHindPaw':'farHock'})

def view(trunk,chest,head,tail,rear,arm,farArm=None,farRear=None,depth=None):
    out={}
    def chain(names,points):
        if points:
            for i,name in enumerate(names.split()):out[name]=[points[2*i:2*i+2],points[2*i+2:2*i+4]]
    chain('trunk',trunk);chain('chest',chest);chain('head',head)
    chain('tail tip',tail);chain('rear rearFoot',rear);chain('arm forearm paw',arm)
    chain('farRear farRearFoot',farRear);chain('farArm farForearm farPaw',farArm)
    return out
SIT=view([66,65,49,49],[47,56,38,34],[36,32,33,14],[79,79,90,88,68,94],[68,58,63,80,56,95],[44,46,43,64,39,87,39,98],[20,48,22,66,24,86,24,97],[54,68,50,84,48,94])
PRONE=view([70,56,48,48],[48,53,34,45],[28,49,25,20],[88,68,93,84,77,92],[76,53,70,78,64,88],[46,50,53,78,38,89,30,95],[17,60,14,78,12,88,11,94])
LOAF=view([66,64,50,52],[48,60,35,43],[36,47,35,21],[83,74,92,86,83,94],[72,59,72,78,67,93],[46,55,57,81,45,91,37,94],[20,60,19,81,18,91,14,93])
SIDE=view([65,46,45,44],[42,48,31,56],[22,63,16,44],[82,56,93,69,90,77],[69,47,65,72,57,86],[47,49,56,68,47,83,37,90],[31,60,32,75,30,88,26,95])
BACK=view([53,62,42,47],[44,49,39,38],[35,26,35,10],[83,66,82,88,40,90],[26,58,20,78,30,91],None)
WALK=view([69,37,50,39],[42,42,28,35],[18,38,12,18],[78,40,85,64,97,77],[67,38,64,70,55,96],[32,36,36,65,39,88,37,96],[25,39,17,65,8,87,5,95],[72,46,78,66,78,95])
CARRY=view([52,64,45,47],[44,45,40,32],[40,27,35,12],[62,74,65,85,64,99],[61,62,61,80,54,92],[57,36,56,47,49,52,46,59],[25,37,20,45,17,52,15,58],[34,68,28,82,22,91])
REAR=view([57,43,41,32],[35,33,23,26],[21,23,17,10],[77,43,83,71,94,81],[60,49,53,76,50,97],[20,38,20,66,17,85,15,96],[33,39,34,64,35,80,33,88],[72,45,74,74,70,94])
JUMP=view([62,55,43,45],[38,44,28,36],[27,30,22,12],[73,53,87,63,97,73],[62,56,74,75,85,94],[39,49,30,49,16,45,8,48],[29,40,22,43,10,39,4,39],[62,52,78,68,90,85])
def changed(base,**chains):
    d=base.copy()
    for names,coords in chains.items():
        for i,n in enumerate(names.split('_')):d[n]=[coords[2*i:2*i+2],coords[2*i+2:2*i+4]]
    return d
def bind(name):return name+'.png'
VIEWS={}
def add(family,keys):
    for k in keys:VIEWS[bind(k)]=family

add(SIT,['settle-0','paw-aim-0','nip-aim-2','swat-aim-0'])
add(changed(SIT,arm_forearm_paw=[36,48,32,60,30,62,27,59]),['paw-aim-1','swat-aim-1'])
add(changed(SIT,arm_forearm_paw=[33,48,26,56,28,40,30,29]),['paw-aim-2'])
add(changed(SIT,farArm_farForearm_farPaw=[52,50,56,50,67,28,72,10],head=[41,33,40,17]),['swat-aim-2'])
add(changed(SIT,head=[47,73,45,51],chest=[51,42,45,60],arm_forearm_paw=[32,66,26,78,24,88,22,95],farArm_farForearm_farPaw=[70,69,68,78,64,88,62,95]),['nip-aim-0'])
add(changed(SIT,head=[43,34,43,16]),['nip-aim-1'])
add(changed(SIT,head=[39,33,38,17],arm_forearm_paw=[40,45,34,55,17,51,6,50],farArm_farForearm_farPaw=[57,49,54,67,51,85,50,96]),['paw-1','swat-1'])
add(changed(SIT,head=[28,34,26,16],arm_forearm_paw=[45,49,44,68,37,87,34,96]),['nip-1'])
add(changed(PRONE,head=[27,37,27,15],arm_forearm_paw=[44,49,42,67,35,84,31,93]),['settle-4'])
add(PRONE,['settle-8','turn-2','turn-3'])
add(changed(PRONE,arm_forearm_paw=[46,45,56,73,48,77,42,80]),['paw-rest-reach','swat-rest-reach'])
add(changed(PRONE,head=[25,63,24,37]),['nip-rest-reach'])
add(changed(PRONE,arm_forearm_paw=[44,48,38,73,49,68,54,59],head=[30,45,32,20]),['Motion/paw-flank-3','Motion/swat-flank-3','Motion/nip-flank-3'])
add(LOAF,['loaf-0','loaf-1','loaf-2'])
add(SIDE,['side-0','side-1','side-2'])
add(BACK,['turn-5'])
add(changed(BACK,head=[57,26,58,10]),['back-2'])
add(CARRY,['carry-0'])
add(changed(CARRY,arm_forearm_paw=[43,37,41,51,35,60,33,65]),['Motion/release-1'])
add(WALK,['walk-1'])
add(changed(WALK,arm_forearm_paw=[38,43,46,68,37,85,24,91],head=[24,39,22,17]),['leap-0'])
add(JUMP,['leap-1'])
add(changed(WALK,chest=[42,51,29,49],head=[18,58,15,34],arm_forearm_paw=[34,48,32,69,20,86,11,96]),['Motion/step-down-5'])
add(REAR,['Motion/stand-turn-9'])
add(changed(REAR,head=[29,21,31,8],trunk=[53,46,44,30],tail_tip=[62,47,66,76,89,83],rear_rearFoot=[47,49,45,76,39,97],farRear_farRearFoot=[60,50,63,70,61,96]),['Motion/stand-turn-11'])
add(changed(BACK,head=[24,31,24,12]),['Motion/stand-turn-13'])

add(PRONE,['settle-6','turn-4'])
add(SIT,['settle-2'])
add(changed(SIT,arm_forearm_paw=[39,48,34,58,23,54,15,53]),['Motion/paw-side-2','Motion/swat-side-2'])
add(changed(BACK,head=[46,30,46,13]),['Motion/back-wake-2'])
add(WALK,['Motion/stand-turn-8','Motion/hop-up-3','Motion/hop-up-5','Motion/step-down-2','Motion/step-down-8'])
add(JUMP,['Motion/release-2'])

add(WALK,['Motion/stand-turn-5'])
add(changed(WALK,head=[20,34,18,11],arm_forearm_paw=[34,41,39,64,26,86,18,96]),['Motion/hop-up-1'])
add(changed(SIT,head=[23,32,21,13],arm_forearm_paw=[32,41,33,68,26,85,23,96]),['Motion/walk-sit-2'])

add(changed(WALK,arm_forearm_paw=[36,43,40,65,24,84,11,95]),['leap-2'])
add(changed(SIT,head=[50,34,51,16]),['Motion/sit-turn-2'])
add(changed(CARRY,rear_rearFoot=[62,62,51,83,38,96],farRear_farRearFoot=[38,64,29,79,16,88]),['carry-2'])

add(changed(WALK,arm_forearm_paw=[34,42,37,64,27,84,18,95]),['Motion/hop-up-7'])
add(changed(SIT,head=[32,30,29,12],arm_forearm_paw=[34,46,28,61,19,59,15,56]),['swat-0'])

# Silhouettes at which a previously hidden limb or the far cheek comes into view.
add(changed(PRONE, head=[42,43,41,18]), ['Motion/prone-turn-2'])
add(changed(PRONE, head=[24,53,21,28]), ['Motion/side-prone-2'])
add(changed(PRONE, arm_forearm_paw=[44,48,52,73,43,77,35,79]), ['Motion/paw-rest-2'])
add(changed(SIT, arm_forearm_paw=[33,47,30,56,24,40,24,34]), ['Motion/paw-high-2'])
add(changed(SIT, head=[41,48,40,29]), ['Motion/nip-low-2'])
add(changed(WALK, head=[23,32,21,13]), ['Motion/stand-turn-3'])
